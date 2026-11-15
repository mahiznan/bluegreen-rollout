package com.example.payments;

/** Thrown when the domain call fails (connection refused, timeout, non-2xx, empty body). */
public class RiskUnavailableException extends RuntimeException {

    public RiskUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
