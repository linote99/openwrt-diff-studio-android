package com.linote.diffstudio.ssh;

import com.linote.diffstudio.core.OtaException;
import org.junit.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

public class RemoteStartCommandTest {
    @Test
    public void startUsesReviewedPatchIdInsteadOfRandomRuntimeId() {
        String runtimeId = "a".repeat(64);
        String reviewedPatchId = "b".repeat(64);
        String stagedPatchId = "c".repeat(64);
        String home = "/tmp/unisoc-ota-" + runtimeId;
        String path = "/etc/unisoc-ota/upload-" + stagedPatchId + ".ota";

        Map<String, Object> check = new LinkedHashMap<>();
        check.put("id", reviewedPatchId);
        Map<String, Object> session = new LinkedHashMap<>();
        session.put("runtime", home);
        session.put("path", path);
        session.put("check", check);

        String command = Remote.runtimeStartCommand(session);
        String rpc = command.substring(command.indexOf("/ota/rpc.py start "));
        assertEquals("/ota/rpc.py start " + Remote.q("/target" + path) + " " + Remote.q(reviewedPatchId), rpc);
        assertTrue(command.contains(Remote.q(home + "/bootstrap.sh") + " " + Remote.q(path) + " inspect "));
    }

    @Test
    public void startRejectsMissingReviewedPatchId() {
        Map<String, Object> session = new LinkedHashMap<>();
        session.put("runtime", "/tmp/unisoc-ota-" + "a".repeat(64));
        session.put("path", "/etc/unisoc-ota/upload-" + "b".repeat(64) + ".ota");
        session.put("check", new LinkedHashMap<>());

        assertThrows(OtaException.class, () -> Remote.runtimeStartCommand(session));
    }
}
