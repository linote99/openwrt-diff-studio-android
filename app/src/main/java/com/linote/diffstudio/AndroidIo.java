package com.linote.diffstudio;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.RouteInfo;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;

import com.linote.diffstudio.core.OtaException;
import com.linote.diffstudio.core.Release;

import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Storage Access Framework and network helpers. */
final class AndroidIo {
    private AndroidIo() {}

    static String displayName(Context ctx, Uri uri) {
        String name = null;
        try (Cursor c = ctx.getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) name = c.getString(0);
        } catch (RuntimeException ignored) {
            // fall back to the path segment
        }
        if (name == null || name.isEmpty()) {
            name = uri.getLastPathSegment();
            if (name != null && name.contains("/")) name = name.substring(name.lastIndexOf('/') + 1);
        }
        return name == null ? "" : name;
    }

    /**
     * Some vendor save dialogs shorten long titles (about 50 characters) and then replace the
     * "extension" with one derived from the MIME type, e.g. "...-20261023.183851-.bin".
     * Restore the intended name/extension on the created document before any data is written.
     * A name the user typed themselves is kept; only its extension is corrected.
     * Returns the (possibly new) document URI.
     */
    static Uri fixSavedName(Context ctx, Uri uri, String intended) {
        if (intended == null || intended.isEmpty()) return uri;
        String actual = displayName(ctx, uri);
        if (actual.equals(intended)) return uri;
        int dot = intended.lastIndexOf('.');
        String ext = dot > 0 ? intended.substring(dot) : ""; // ".zip" / ".ota"
        String stem = dot > 0 ? intended.substring(0, dot) : intended;
        String base = actual;
        boolean extOk = !ext.isEmpty() && base.toLowerCase(Locale.ROOT).endsWith(ext.toLowerCase(Locale.ROOT));
        if (extOk) {
            base = base.substring(0, base.length() - ext.length());
        } else {
            // drop a substituted extension such as ".bin" (short alphanumeric suffix)
            Matcher m = Pattern.compile("\\.[A-Za-z0-9]{1,5}$").matcher(base);
            if (m.find()) base = base.substring(0, m.start());
        }
        // a provider uniqueness suffix like " (1)" is kept but ignored for the comparison
        String core = base.replaceFirst(" \\(\\d+\\)$", "");
        String suffix = base.substring(core.length());
        String wantedStem;
        if (core.isEmpty() || stem.startsWith(core)) wantedStem = stem + suffix; // shortened by the dialog
        else if (extOk) return uri; // the user chose a different, valid name
        else wantedStem = base; // the user's own name with a wrong extension
        List<String> tries = new ArrayList<>();
        tries.add(wantedStem + ext);
        for (int i = 1; i <= 20; i++) tries.add(wantedStem + " (" + i + ")" + ext);
        for (String name : tries) {
            if (name.equals(actual)) return uri;
            try {
                Uri renamed = DocumentsContract.renameDocument(ctx.getContentResolver(), uri, name);
                return renamed != null ? renamed : uri;
            } catch (FileNotFoundException | RuntimeException e) {
                // retry with the next candidate only when the name is already taken
                String msg = String.valueOf(e.getMessage()).toLowerCase(Locale.ROOT);
                if (!(msg.contains("exist") || msg.contains("already") || msg.contains("conflict") || msg.contains("unique")))
                    return uri;
            }
        }
        return uri;
    }

    /** Largest writable scratch directory (the E5 root image is decompressed there temporarily). */
    static File scratch(Context ctx) {
        File best = ctx.getCacheDir();
        File[] ext = ctx.getExternalCacheDirs();
        if (ext != null) for (File f : ext) {
            if (f != null && f.isDirectory() && f.canWrite() && f.getUsableSpace() > best.getUsableSpace()) best = f;
        }
        File dir = new File(best, "work");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        return dir;
    }

    /** Random-access release source; providers without seekable descriptors are copied to scratch first. */
    static Release.Source openRelease(Context ctx, Uri uri, File scratch) throws IOException {
        String name = displayName(ctx, uri);
        ContentResolver cr = ctx.getContentResolver();
        ParcelFileDescriptor pfd = null;
        try {
            pfd = cr.openFileDescriptor(uri, "r");
        } catch (SecurityException e) {
            throw new OtaException("Select the file again: access was revoked (" + e.getMessage() + ")");
        }
        if (pfd == null) throw new OtaException("Cannot open " + name);
        final ParcelFileDescriptor fd = pfd;
        FileInputStream fis = new FileInputStream(fd.getFileDescriptor());
        FileChannel ch = fis.getChannel();
        boolean seekable;
        try {
            long size = ch.size();
            ch.position(Math.max(0, size - 1));
            ch.position(0);
            seekable = size > 0 && fd.getStatSize() >= 0;
        } catch (IOException e) {
            seekable = false;
        }
        if (seekable) {
            Closeable owner = () -> {
                try {
                    fis.close();
                } finally {
                    fd.close();
                }
            };
            return new Release.Source(ch, name, owner);
        }
        fis.close();
        fd.close();
        final File copy = File.createTempFile("release", ".zip", scratch);
        try (InputStream in = cr.openInputStream(uri); OutputStream out = new FileOutputStream(copy)) {
            if (in == null) throw new OtaException("Cannot open " + name);
            byte[] buf = new byte[1 << 20];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } catch (IOException | RuntimeException e) {
            copy.delete();
            throw e;
        }
        final RandomAccessFile raf = new RandomAccessFile(copy, "r");
        Closeable owner = () -> {
            try {
                raf.close();
            } finally {
                copy.delete();
            }
        };
        return new Release.Source(raf.getChannel(), name, owner);
    }

    static void copyToFile(Context ctx, Uri uri, File dest) throws IOException {
        try (InputStream in = ctx.getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(dest)) {
            if (in == null) throw new OtaException("Cannot open the selected file");
            byte[] buf = new byte[1 << 20];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
    }

    static void copyToUri(Context ctx, File src, Uri uri) throws IOException {
        try (InputStream in = new FileInputStream(src); OutputStream out = ctx.getContentResolver().openOutputStream(uri, "wt")) {
            if (out == null) throw new OtaException("Cannot write the selected destination");
            byte[] buf = new byte[1 << 20];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
    }

    /**
     * Connect over the network whose routes reach the device. A router being updated often offers
     * Wi-Fi without internet; Android would otherwise send LAN traffic to the mobile data default network.
     */
    static Socket connect(Context ctx, String host, int port, int timeoutMs) throws IOException {
        ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        InetAddress address = null;
        Network chosen = null;
        if (cm != null) {
            int bestPrefix = -1;
            for (Network n : cm.getAllNetworks()) {
                LinkProperties lp = cm.getLinkProperties(n);
                NetworkCapabilities caps = cm.getNetworkCapabilities(n);
                if (lp == null || caps == null || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
                InetAddress a;
                try {
                    a = address != null ? address : resolve(n, host);
                } catch (IOException e) {
                    continue;
                }
                for (RouteInfo r : lp.getRoutes()) {
                    int prefix = r.getDestination().getPrefixLength();
                    if (prefix > 0 && r.matches(a) && prefix > bestPrefix) {
                        bestPrefix = prefix;
                        chosen = n;
                        address = a;
                    }
                }
            }
        }
        Socket s;
        if (chosen != null) {
            s = chosen.getSocketFactory().createSocket();
        } else {
            address = InetAddress.getByName(host);
            s = new Socket();
        }
        try {
            s.setTcpNoDelay(true);
            s.connect(new InetSocketAddress(address, port), timeoutMs);
        } catch (IOException e) {
            s.close();
            throw e;
        }
        return s;
    }

    private static InetAddress resolve(Network n, String host) throws IOException {
        return n.getByName(host);
    }
}
