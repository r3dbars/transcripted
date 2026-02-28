// IsRetryableTests.swift
// Tests for AnthropicAPIError.isRetryable()

import Foundation

func testIsRetryable() {
    // MARK: - Retryable errors

    runSuite("isRetryable — overloaded is retryable") {
        assertTrue(AnthropicAPIError.isRetryable(AnthropicAPIError.overloaded))
    }

    runSuite("isRetryable — URLError notConnectedToInternet") {
        let err = URLError(.notConnectedToInternet)
        assertTrue(AnthropicAPIError.isRetryable(err))
    }

    runSuite("isRetryable — URLError networkConnectionLost") {
        let err = URLError(.networkConnectionLost)
        assertTrue(AnthropicAPIError.isRetryable(err))
    }

    runSuite("isRetryable — URLError timedOut") {
        let err = URLError(.timedOut)
        assertTrue(AnthropicAPIError.isRetryable(err))
    }

    // MARK: - Non-retryable errors

    runSuite("isRetryable — noCredential is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.noCredential))
    }

    runSuite("isRetryable — invalidResponse is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.invalidResponse))
    }

    runSuite("isRetryable — emptyResponse is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.emptyResponse))
    }

    runSuite("isRetryable — apiError is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.apiError("rate limited")))
    }

    runSuite("isRetryable — subscriptionTokenExpired is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.subscriptionTokenExpired))
    }

    runSuite("isRetryable — timeout is NOT retryable") {
        assertFalse(AnthropicAPIError.isRetryable(AnthropicAPIError.timeout))
    }

    runSuite("isRetryable — URLError badURL is NOT retryable") {
        let err = URLError(.badURL)
        assertFalse(AnthropicAPIError.isRetryable(err))
    }

    runSuite("isRetryable — generic Swift error is NOT retryable") {
        struct CustomError: Error {}
        assertFalse(AnthropicAPIError.isRetryable(CustomError()))
    }
}
