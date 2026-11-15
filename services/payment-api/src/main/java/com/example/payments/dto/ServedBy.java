package com.example.payments.dto;

import com.fasterxml.jackson.annotation.JsonInclude;

/** "Who answered?" One per hop. secretFingerprint is the first 8 hex of SHA-256 of the secret. */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ServedBy(String service, String commit, String pod, String secretFingerprint) {
}
