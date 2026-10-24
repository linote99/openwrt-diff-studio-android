package com.linote.diffstudio.ssh;

import com.jcraft.jsch.ChannelExec;
import com.jcraft.jsch.JSch;
import com.jcraft.jsch.JSchException;
import com.jcraft.jsch.Session;
import com.jcraft.jsch.UIKeyboardInteractive;
import com.jcraft.jsch.UserInfo;
import com.linote.diffstudio.core.Json;
import com.linote.diffstudio.core.Ota;
import com.linote.diffstudio.core.OtaException;
import com.linote.diffstudio.core.Py;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.security.SecureRandom;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Port of ota_desktop.py: SSH updater with review token, host-key pinning and detached device transaction. */
public final class Remote {
    public interface Events {
        void progress(Map<String, Object> data);
    }

    /** Optional socket source (Android binds sockets to the Wi-Fi/LAN network that reaches the device). */
    public interface SocketSource {
        Socket create(String host, int port, int timeoutMs) throws IOException;
    }

    static {
        JSch.setConfig("xdh", "com.jcraft.jsch.bc.XDH");
        JSch.setConfig("keypairgen.eddsa", "com.jcraft.jsch.bc.KeyPairGenEdDSA");
        JSch.setConfig("ssh-ed25519", "com.jcraft.jsch.bc.SignatureEd25519");
        JSch.setConfig("ssh-ed448", "com.jcraft.jsch.bc.SignatureEd448");
        // Old Dropbear builds on vendor firmware: keep legacy algorithms available, as paramiko does.
        append("kex", "diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1");
        append("server_host_key", "ssh-rsa,ssh-dss");
        append("cipher.s2c", "aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc");
        append("cipher.c2s", "aes128-cbc,aes192-cbc,aes256-cbc,3des-cbc");
        append("mac.s2c", "hmac-sha1,hmac-sha1-96,hmac-md5");
        append("mac.c2s", "hmac-sha1,hmac-sha1-96,hmac-md5");
    }

    private static void append(String key, String extra) {
        String cur = JSch.getConfig(key);
        StringBuilder sb = new StringBuilder(cur == null ? "" : cur);
        for (String a : extra.split(",")) {
            if (cur != null && (("," + cur + ",").contains("," + a + ","))) continue;
            if (sb.length() > 0) sb.append(',');
            sb.append(a);
        }
        JSch.setConfig(key, sb.toString());
    }

    private final File root;
    private final Events events;
    private final SocketSource sockets;
    private final SecureRandom random = new SecureRandom();

    private Map<String, Object> review;
    private Map<String, Object> runtimeSession;
    private File archivePath;
    private final Set<String> activated = new HashSet<>();
    private Map<String, Object> pendingReboot;

    public Remote(File root, Events events, SocketSource sockets) {
        this.root = root;
        this.events = events == null ? d -> { } : events;
        this.sockets = sockets;
    }

    private String tokenHex(int n) {
        byte[] b = new byte[n];
        random.nextBytes(b);
        return Py.hex(b);
    }

    // ------------------------------------------------------------------ SSH plumbing
    public static final class Client implements AutoCloseable {
        final Session session;

        Client(Session s) { session = s; }

        public String hostKeySha256() {
            byte[] blob = java.util.Base64.getDecoder().decode(session.getHostKey().getKey());
            return Py.sha256Hex(blob);
        }

        @Override
        public void close() {
            session.disconnect();
        }
    }

    public Client connect(String host, String password) throws JSchException {
        if (host == null || host.isEmpty() || host.length() > 253) throw new OtaException("Enter the device management address");
        for (int i = 0; i < host.length(); i++) if (Py.isPySpace(host.charAt(i))) throw new OtaException("Enter the device management address");
        String h = host;
        int port = 22;
        int colon = host.indexOf(':');
        if (colon > 0 && colon == host.lastIndexOf(':') && host.substring(colon + 1).matches("\\d{1,5}")) {
            h = host.substring(0, colon);
            port = Integer.parseInt(host.substring(colon + 1));
        } else if (host.startsWith("[") && host.contains("]:")) {
            int e = host.indexOf("]:");
            h = host.substring(1, e);
            port = Integer.parseInt(host.substring(e + 2));
        }
        JSch jsch = new JSch();
        Session s = jsch.getSession("root", h, port);
        final String pw = password == null ? "" : password;
        s.setPassword(pw);
        s.setUserInfo(new KbdInteractive(pw));
        s.setConfig("StrictHostKeyChecking", "no");
        s.setConfig("PreferredAuthentications", "password,keyboard-interactive");
        s.setConfig("HashKnownHosts", "no");
        s.setConfig("MaxAuthTries", "2"); // paramiko: one password attempt (+ keyboard-interactive fallback)
        if (sockets != null) {
            s.setSocketFactory(new com.jcraft.jsch.SocketFactory() {
                @Override
                public Socket createSocket(String host1, int port1) throws IOException {
                    return sockets.create(host1, port1, 15000);
                }

                @Override
                public InputStream getInputStream(Socket socket) throws IOException {
                    return socket.getInputStream();
                }

                @Override
                public OutputStream getOutputStream(Socket socket) throws IOException {
                    return socket.getOutputStream();
                }
            });
        }
        try {
            s.connect(15000);
            s.setTimeout(0);
        } catch (JSchException e) {
            s.disconnect();
            throw e;
        }
        return new Client(s);
    }

    private static final class KbdInteractive implements UserInfo, UIKeyboardInteractive {
        final String pw;

        int kbdPrompts;
        KbdInteractive(String pw) { this.pw = pw; }

        @Override public String getPassphrase() { return null; }
        @Override public String getPassword() { return pw; }
        @Override public boolean promptPassword(String message) { return false; } // the password was already tried once
        @Override public boolean promptPassphrase(String message) { return false; }
        @Override public boolean promptYesNo(String message) { return true; }
        @Override public void showMessage(String message) { }

        @Override
        public String[] promptKeyboardInteractive(String destination, String name, String instruction, String[] prompt, boolean[] echo) {
            if (kbdPrompts++ > 0) return null;
            String[] r = new String[prompt.length];
            for (int i = 0; i < r.length; i++) r[i] = pw;
            return r;
        }
    }

    /** Runs a command; raises with combined stdout+stderr on non-zero exit, like execute(). */
    public static String execute(Client client, String command, long timeoutSec) throws JSchException, IOException {
        ChannelExec ch = (ChannelExec) client.session.openChannel("exec");
        ch.setCommand(command);
        ch.setInputStream(null);
        InputStream out = ch.getInputStream();
        InputStream err = ch.getErrStream();
        ch.connect(20000);
        ByteArrayOutputStream o = new ByteArrayOutputStream(), e = new ByteArrayOutputStream();
        long deadline = System.nanoTime() + timeoutSec * 1_000_000_000L;
        byte[] buf = new byte[65536];
        try {
            while (true) {
                boolean got = false;
                while (out.available() > 0) {
                    int n = out.read(buf, 0, Math.min(buf.length, out.available()));
                    if (n <= 0) break;
                    o.write(buf, 0, n);
                    got = true;
                }
                while (err.available() > 0) {
                    int n = err.read(buf, 0, Math.min(buf.length, err.available()));
                    if (n <= 0) break;
                    e.write(buf, 0, n);
                    got = true;
                }
                if (o.size() + e.size() > 32 << 20) throw new OtaException("Device response exceeded limit");
                if (ch.isClosed() && out.available() == 0 && err.available() == 0) break;
                if (System.nanoTime() > deadline) throw new OtaException("Device update is still running; reconnect and check status");
                if (!got) Thread.sleep(20);
            }
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new OtaException("Interrupted");
        } finally {
            ch.disconnect();
        }
        int code = ch.getExitStatus();
        String so = Py.decodeUtf8Replace(o.toByteArray(), 0, o.size());
        if (code != 0) {
            throw new OtaException(so + Py.decodeUtf8Replace(e.toByteArray(), 0, e.size()));
        }
        return so;
    }

    public static String execute(Client client, String command) throws JSchException, IOException {
        return execute(client, command, 1800);
    }

    public interface Upload {
        void sent(long done);
    }

    /** exec `command` with `data` on stdin then EOF; returns the exit status. */
    static int upload(Client client, String command, InputStream data, Upload progress) throws JSchException, IOException {
        ChannelExec ch = (ChannelExec) client.session.openChannel("exec");
        ch.setCommand(command);
        ByteArrayOutputStream sink = new ByteArrayOutputStream();
        ch.setOutputStream(sink, true);
        ch.setErrStream(sink, true);
        OutputStream os = ch.getOutputStream();
        ch.connect(20000);
        try {
            byte[] buf = new byte[128 << 10];
            long sent = 0;
            int n;
            while ((n = data.read(buf)) > 0) {
                os.write(buf, 0, n);
                sent += n;
                if (progress != null) progress.sent(sent);
            }
            os.flush();
            os.close(); // flush + SSH EOF (shutdown_write)
            while (!ch.isClosed()) Thread.sleep(20);
            return ch.getExitStatus();
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new OtaException("Interrupted");
        } finally {
            ch.disconnect();
        }
    }

    // ------------------------------------------------------------------ protocol
    static String q(String s) {
        return Py.shlexQuote(s);
    }

    public Map<String, Object> remotePrepare(Client client, File archive) throws IOException, JSchException {
        try (Ota.Patch patch = new Ota.Patch(archive)) {
            if (!Json.truthy(patch.manifest.get("runtime"))) throw new OtaException("This patch does not contain a portable updater runtime");
            String runtime = "/tmp/unisoc-ota-" + tokenHex(32);
            execute(client, "umask 077; mkdir " + q(runtime));
            String bb = q(runtime + "/busybox");
            String[][] helpers = {{"busybox", "busybox"}, {"bootstrap", "bootstrap.sh"}};
            for (String[] kv : helpers) {
                Map<String, Object> desc = Json.map(patch.manifest.get(kv[0]));
                byte[] content = patch.blob((String) desc.get("sha256"));
                String cat = kv[0].equals("busybox") ? "cat" : bb + " cat";
                int code = upload(client, "umask 077; " + cat + " > " + q(runtime + "/" + kv[1]), new java.io.ByteArrayInputStream(content), null);
                if (code != 0) throw new OtaException("Runtime helper upload failed");
                if (kv[0].equals("busybox")) execute(client, "chmod 700 " + q(runtime + "/busybox"));
                String got = first(execute(client, bb + " sha256sum " + q(runtime + "/" + kv[1])));
                if (!got.equals(desc.get("sha256"))) throw new OtaException("Runtime helper checksum mismatch");
            }
            Set<String> available = new HashSet<>(Py.splitlines(execute(client, bb + " --list")));
            String[] required = {"sh", "cat", "chmod", "mkdir", "df", "sha256sum", "mv", "unzip", "cp", "ln", "rm", "mount", "chroot", "reboot"};
            java.util.TreeSet<String> missing = new java.util.TreeSet<>();
            for (String r : required) if (!available.contains(r)) missing.add(r);
            if (!missing.isEmpty()) throw new OtaException("Packaged updater BusyBox lacks: " + String.join(", ", missing));
            String destination = "/etc/unisoc-ota/upload-" + patch.id + ".ota";
            final long total = archive.length();
            List<String> dfLines = Py.splitlines(execute(client, bb + " df -Pk /etc"));
            List<String> cols = Py.splitWhitespace(dfLines.get(dfLines.size() - 1), -1);
            long free;
            try {
                free = Long.parseLong(cols.get(cols.size() - 3)) * 1024;
            } catch (RuntimeException ex) {
                throw new OtaException("invalid literal for int() with base 10: " + Py.repr(cols.isEmpty() ? "" : cols.get(Math.max(0, cols.size() - 3))));
            }
            if (total + (32L << 20) > free) throw new OtaException("Insufficient device staging space");
            execute(client, "umask 077; " + bb + " mkdir -p /etc/unisoc-ota");
            String expected;
            try (InputStream in = new FileInputStream(archive)) {
                expected = Py.digest(in);
            }
            final long[] last = {0};
            int code;
            try (InputStream in = new FileInputStream(archive)) {
                code = upload(client, "umask 077; " + bb + " cat > " + q(destination + ".new"), in, done -> {
                    long now = System.nanoTime();
                    if (now - last[0] > 200_000_000L || done == total) {
                        last[0] = now;
                        Map<String, Object> d = new LinkedHashMap<>();
                        d.put("stage", "upload");
                        d.put("done", done);
                        d.put("total", total);
                        events.progress(d);
                    }
                });
            }
            if (code != 0) throw new OtaException("Device upload failed");
            String got = first(execute(client, bb + " sha256sum " + q(destination + ".new")));
            if (!got.equals(expected)) throw new OtaException("Device upload checksum mismatch");
            execute(client, bb + " mv " + q(destination + ".new") + " " + q(destination));
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("path", destination);
            r.put("runtime", runtime);
            return r;
        }
    }

    private static String first(String s) {
        List<String> p = Py.splitWhitespace(s, -1);
        if (p.isEmpty()) throw new OtaException("IndexError: list index out of range");
        return p.get(0);
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> runtimeCall(Client client, Map<String, Object> session, String command, boolean setup) throws IOException, JSchException {
        String home = (String) session.get("runtime");
        String shell;
        if (setup) {
            shell = String.join(" ", q(home + "/busybox"), "sh", q(home + "/bootstrap.sh"), q((String) session.get("path")), q(command), q(home));
        } else {
            shell = "UNISOC_OTA_ROOT=/target UNISOC_OTA_RAM=/ UNISOC_OTA_LIVE=1 PYTHONHOME=/usr " + q(home + "/busybox") + " chroot "
                    + q(home + "/root") + " /usr/bin/python3 /ota/rpc.py " + q(command);
        }
        Object v = Json.parse(execute(client, shell));
        Map<String, Object> m = Json.map(v);
        if (m == null) throw new OtaException("Unexpected device response");
        return m;
    }

    Map<String, Object> remoteInspect(Client client, File archive) throws IOException, JSchException {
        Map<String, Object> session = remotePrepare(client, archive);
        Map<String, Object> r = new LinkedHashMap<>(session);
        r.put("check", runtimeCall(client, session, "inspect", true));
        return r;
    }

    static Map<String, Object> refreshRpc(Client client) throws IOException, JSchException, InterruptedException {
        execute(client, "/etc/init.d/rpcd reload", 15);
        long deadline = System.nanoTime() + 5_000_000_000L;
        while (true) {
            try {
                Map<String, Object> value = Json.map(Json.parse(execute(client, "ubus call unisoc-ota status", 3)));
                if (value != null && value.containsKey("identity") && !Json.truthy(value.get("error"))) {
                    Map<String, Object> r = new LinkedHashMap<>();
                    r.put("status", "ready");
                    return r;
                }
            } catch (OtaException ignored) {
                // RuntimeError / ValueError: still registering
            }
            if (System.nanoTime() >= deadline) throw new OtaException("unisoc-ota RPC did not register after reload");
            Thread.sleep(100);
        }
    }

    // ------------------------------------------------------------------ commands (Desktop.dispatch)
    /** ota_probe */
    public synchronized Map<String, Object> probe(String host, String password, File path) throws Exception {
        review = null;
        File archive = path != null ? path : (archivePath != null ? archivePath : new File(root, "update.ota"));
        archivePath = archive;
        Map<String, Object> result;
        String key;
        try (Client client = connect(host, password)) {
            result = remoteInspect(client, archive);
            key = client.hostKeySha256();
        }
        String token = tokenHex(24);
        Map<String, Object> rv = new LinkedHashMap<>();
        rv.put("host", host);
        rv.put("key", key);
        rv.put("token", token);
        rv.putAll(result);
        review = rv;
        Map<String, Object> rs = new LinkedHashMap<>();
        rs.put("host", host);
        rs.put("key", key);
        rs.putAll(result);
        runtimeSession = rs;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("token", token);
        out.putAll(result);
        return out;
    }

    /** ota_apply */
    public synchronized Map<String, Object> apply(String host, String password, String token, boolean autoReboot) throws Exception {
        Map<String, Object> r = review;
        if (r == null || token == null || !token.equals(r.get("token")) || !host.equals(r.get("host")))
            throw new OtaException("Review this device and patch before applying");
        try (Client client = connect(host, password)) {
            String key = client.hostKeySha256();
            if (!key.equals(r.get("key"))) throw new OtaException("Device SSH identity changed since review");
            Map<String, Object> result = runtimeCall(client, r, "start", true);
            runtimeSession = r;
            if (autoReboot) {
                Map<String, Object> p = new LinkedHashMap<>();
                p.put("host", r.get("host"));
                p.put("key", r.get("key"));
                p.put("id", Json.map(r.get("check")).get("id"));
                pendingReboot = p;
            } else {
                pendingReboot = null;
            }
            review = null;
            return result;
        }
    }

    /** ota_reboot */
    public synchronized Map<String, Object> reboot(String host, String password) throws Exception {
        try (Client client = connect(host, password)) {
            String key = client.hostKeySha256();
            Map<String, Object> session = runtimeSession;
            if (session == null || !host.equals(session.get("host")) || !key.equals(session.get("key")))
                throw new OtaException("Check this device before rebooting");
            Map<String, Object> status = runtimeCall(client, session, "status", false);
            Map<String, Object> job = Json.map(status.get("job"));
            Map<String, Object> tx = Json.map(status.get("transaction"));
            String txs = tx == null ? null : Json.str(tx.get("status"));
            if ((job != null && "running".equals(job.get("status"))) || "applying".equals(txs) || "rolling_back".equals(txs))
                throw new OtaException("The device is still updating; do not reboot");
            pendingReboot = null;
            return runtimeCall(client, session, "reboot", false);
        }
    }

    /** ota_status */
    public synchronized Map<String, Object> status(String host, String password, File path) throws Exception {
        try (Client client = connect(host, password)) {
            String key = client.hostKeySha256();
            Map<String, Object> session = runtimeSession;
            boolean setup = session == null || !host.equals(session.get("host")) || !key.equals(session.get("key"));
            if (!setup) {
                String home = (String) session.get("runtime");
                String ready = Py.strip(execute(client, "if test -x " + q(home + "/busybox") + " && test -x " + q(home + "/root/usr/bin/python3")
                        + " && test -d " + q(home + "/root/target/etc") + "; then echo ready; fi"));
                setup = !ready.equals("ready");
            }
            if (setup) {
                File archive = path != null ? path : (archivePath != null ? archivePath : new File(root, "update.ota"));
                if (!archive.isFile()) throw new OtaException("Select the OTA patch before checking this old device");
                Map<String, Object> s = new LinkedHashMap<>();
                s.put("host", host);
                s.put("key", key);
                s.putAll(remotePrepare(client, archive));
                session = s;
            }
            Map<String, Object> result = runtimeCall(client, session, "status", setup);
            runtimeSession = session;
            Map<String, Object> transaction = Json.map(result.get("transaction"));
            if (transaction == null) transaction = new LinkedHashMap<>();
            Map<String, Object> job = Json.map(result.get("job"));
            if (job == null) job = new LinkedHashMap<>();
            Object txStatus = transaction.get("status");
            if ("complete".equals(job.get("status")) && ("complete".equals(txStatus) || "rolled_back".equals(txStatus))) {
                String marker = host + "\0" + key + "\0" + transaction.get("id") + "\0" + txStatus;
                Map<String, Object> jr = Json.map(job.get("result"));
                Map<String, Object> activation = jr == null ? null : Json.map(jr.get("activation"));
                if (activation == null) activation = new LinkedHashMap<>();
                if (activated.contains(marker)) {
                    activation = new LinkedHashMap<>();
                    activation.put("status", "ready");
                }
                if (!activated.contains(marker) && !"ready".equals(activation.get("status"))) {
                    try {
                        activation = refreshRpc(client);
                    } catch (Exception error) {
                        activation = new LinkedHashMap<>();
                        activation.put("status", "warning");
                        activation.put("error", String.valueOf(error.getMessage()));
                    }
                }
                if ("ready".equals(activation.get("status"))) activated.add(marker);
                result.put("activation", activation);
                Map<String, Object> pending = pendingReboot;
                if (pending != null && host.equals(pending.get("host")) && key.equals(pending.get("key"))
                        && Json.pyEquals(pending.get("id"), transaction.get("id"))) {
                    pendingReboot = null;
                    try {
                        result.put("reboot", runtimeCall(client, session, "reboot", false));
                    } catch (Exception error) {
                        Map<String, Object> f = new LinkedHashMap<>();
                        f.put("status", "failed");
                        f.put("error", String.valueOf(error.getMessage()));
                        result.put("reboot", f);
                    }
                }
            } else if ("failed".equals(job.get("status"))) {
                pendingReboot = null;
            }
            return result;
        }
    }

    /** Selecting a new patch invalidates any earlier review (ota_package). */
    public synchronized void selectPatch(File archive) {
        archivePath = archive;
        review = null;
    }
}
