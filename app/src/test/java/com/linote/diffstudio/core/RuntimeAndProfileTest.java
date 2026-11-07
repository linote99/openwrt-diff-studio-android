package com.linote.diffstudio.core;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class RuntimeAndProfileTest {
    private static Map<String, Object> meta(String profile, String imageVersion) {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("profile", profile);
        value.put("image_version", imageVersion);
        value.put("openwrt", "25.12.5");
        value.put("kernel_release", "6.12.94-u30pro-p1");
        return value;
    }

    @Test
    public void patchFilenameUsesUpstreamNativeProfileLabels() {
        Map<String, Object> old = meta("f50pro", "r20261001.000000-g1234567890");
        Map<String, Object> f50 = meta("f50pro", "r20261106.144559-g0696fbc2");
        Map<String, Object> u30 = meta("u30pro", "r20261106.144559-g0696fbc2");
        Map<String, Object> lym = meta("lym10k", "r20261106.144559-g0696fbc2");

        assertTrue(OtaPackage.patchFilename(old, f50, "new.zip").contains("-F50Pro-"));
        assertTrue(OtaPackage.patchFilename(old, u30, "new.zip").contains("-U30Pro-"));
        assertTrue(OtaPackage.patchFilename(old, lym, "new.zip").contains("-LYM-10K-"));
    }

    @Test
    public void generatedBootstrapSeparatesSessionIdFromReviewedPatchId() {
        String script = new String(OtaRuntime.bootstrap(new LinkedHashMap<>()), StandardCharsets.UTF_8);

        assertTrue(script.contains("session=${home#/tmp/unisoc-ota-}"));
        assertTrue(script.contains("id=${4:-}"));
        assertTrue(script.contains("upload-*.ota"));
        assertTrue(script.contains("reviewed-*.ota"));
        assertTrue(script.contains("/ota/rpc.py start \"/target$patch\" \"$id\""));
        assertFalse(script.contains("id=${home#/tmp/unisoc-ota-}"));
    }
}
