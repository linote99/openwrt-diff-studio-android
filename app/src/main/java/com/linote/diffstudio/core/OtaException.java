package com.linote.diffstudio.core;

/** Equivalent of the ValueError/RuntimeError messages raised by the original backend. */
public class OtaException extends RuntimeException {
    public OtaException(String message) {
        super(message);
    }

    public OtaException(String message, Throwable cause) {
        super(message, cause);
    }
}
