package com.example.payments.dto;

/** Both hops of the call chain, so one response shows eAPI and domain side by side. */
public record Served(ServedBy eapi, ServedBy domain) {
}
