package com.linote.diffstudio.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/** Port of ota_bundle.export_bundle for Android: update.ota + fingerprinted Python updater + README. */
public final class Bundle {
    private Bundle() {}

    public interface Files {
        InputStream open(String name) throws IOException;
    }

    public static final String README = "# OpenWrt differential OTA\n\n"
            + "Web: import update.ota in System > System patches.\n"
            + "Android: open OpenWrt Diff Studio, choose Update device, select update.ota and connect to DEVICE_IP.\n"
            + "Python: python OpenWrt-Updater.py update update.ota --host DEVICE_IP (requires paramiko).\n\n"
            + "网页：系统 → 系统补丁，导入 update.ota。\n"
            + "安卓：打开 OpenWrt Diff Studio → 更新设备，选择 update.ota 后连接设备。\n"
            + "电脑：完整解压后运行 python OpenWrt-Updater.py update update.ota --host 设备地址（需要 paramiko）。\n"
            + "仅使用可信补丁；先核对目标版本、机型和冲突检查。\n"
            + "更新后请重启；网页支持撤销上次补丁。\n"
            + "旧系统没有 OTA 插件／Python：使用安卓或电脑更新程序首次更新，完成后即可在网页导入后续补丁。\n"
            + "Old system without OTA/Python: use the Android or desktop updater once; subsequent patches can be imported in LuCI.\n";

    @SuppressWarnings("unchecked")
    public static void export(File patch, File output, Files runtime) throws IOException {
        Map<String, Object> build;
        try (InputStream in = runtime.open("files.json")) {
            build = Json.map(Json.parse(Py.readAll(in)));
        }
        Map<String, Object> files = build == null ? null : Json.map(build.get("files"));
        if (build == null || !Json.pyEquals(build.get("protocol"), 1L) || files == null || files.isEmpty())
            throw new OtaException("Missing Diff Studio runtime manifest; run installer/build-ota.py");
        for (Map.Entry<String, Object> e : files.entrySet()) {
            Ota.safeName(e.getKey());
            try (InputStream in = runtime.open(e.getKey())) {
                if (!Py.digest(in).equals(e.getValue())) throw new OtaException("Native runtime checksum mismatch: " + e.getKey());
            } catch (java.io.FileNotFoundException missing) {
                throw new OtaException("Missing or unsafe native runtime file");
            }
        }
        if (output.exists()) throw new OtaException("Output already exists");
        File tmp = new File(output.getPath() + ".building");
        if (tmp.exists()) throw new OtaException("Output staging exists");
        try {
            ZipOut z = new ZipOut(tmp);
            boolean ok = false;
            try {
                try (InputStream in = new FileInputStream(patch); OutputStream out = z.openEntry("update.ota")) {
                    OtaPackage.copy(in, out);
                }
                for (String name : files.keySet()) {
                    try (InputStream in = runtime.open(name); OutputStream out = z.openEntry(name)) {
                        OtaPackage.copy(in, out);
                    }
                }
                z.writeBytes("README.md", README.getBytes(StandardCharsets.UTF_8));
                ok = true;
            } finally {
                if (ok) z.close();
                else z.abort();
            }
            if (!tmp.renameTo(output)) throw new OtaException("Cannot move finished bundle into place");
        } finally {
            if (tmp.exists()) tmp.delete();
        }
    }
}
