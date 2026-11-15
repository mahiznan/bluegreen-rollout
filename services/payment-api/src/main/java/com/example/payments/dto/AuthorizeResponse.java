package com.example.payments.dto;

/**
 * Result of an authorization.
 *
 * @param receipt  short reference derived from authId. Added in a later release as an ADDITIVE field, so
 *                 clients of the earlier release simply ignore it.
 * @param replayed true when served from this pod's idempotency store. A replay does NOT call
 *                 the domain again, so served.domain is from the original call. served.eapi is
 *                 always the pod that answered THIS request.
 */
public record AuthorizeResponse(
        String authId,
        String status,
        String orderId,
        boolean replayed,
        RiskSummary risk,
        Served served,
        String receipt) {

    public AuthorizeResponse asReplay(ServedBy currentEapi) {
        return new AuthorizeResponse(authId, status, orderId, true, risk, new Served(currentEapi, served.domain()), receipt);
    }
}
