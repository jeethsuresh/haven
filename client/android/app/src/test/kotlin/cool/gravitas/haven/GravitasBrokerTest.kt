package cool.gravitas.haven

import org.junit.Assert.*
import org.junit.Test

class GravitasBrokerTest {
    private val challenge = "c".repeat(43)
    private val state = "s".repeat(43)
    private class Platform : BrokerPlatform {
        var trusted = true
        var available = true
        var names = listOf("@alice:gravitas.cool")
        var requests = 0
        val invalidated = mutableListOf<String>()
        val response = mutableMapOf<String, Any?>(
            "authtoken" to "t".repeat(43), "protocolVersion" to 1,
            "state" to "s".repeat(43), "codeChallenge" to "c".repeat(43),
            "accountName" to "@alice:gravitas.cool", "accountType" to BrokerProtocol.ACCOUNT_TYPE,
            "issuer" to BrokerProtocol.ISSUER, "appOrigin" to BrokerProtocol.ORIGIN, "redirectUri" to BrokerProtocol.REDIRECT,
            "subject" to "alice", "sessionId" to "11111111-1111-4111-8111-111111111111",
        )
        override fun trusted() = trusted
        override fun prepare() = available
        override fun accounts() = names
        override fun request(account: String, type: String, challenge: String, state: String): Map<String, Any?> {
            assertEquals("gravitas_code:haven:v1:$challenge:$state", type)
            requests++
            return response
        }
        override fun invalidate(code: String) { invalidated.add(code) }
    }
    @Test fun pinsTheStoreCertificateAndRequestProof() {
        assertTrue(BrokerProtocol.trusted(BrokerProtocol.PACKAGE, BrokerProtocol.ACCOUNT_TYPE, listOf(BrokerProtocol.CERTIFICATE)))
        assertFalse(BrokerProtocol.trusted(BrokerProtocol.PACKAGE, BrokerProtocol.ACCOUNT_TYPE, listOf("0".repeat(64))))
        assertFalse(BrokerProtocol.trusted("other", BrokerProtocol.ACCOUNT_TYPE, listOf(BrokerProtocol.CERTIFICATE)))
        assertTrue(runCatching { BrokerProtocol.tokenType("bad", state) }.isFailure)
    }
    @Test fun approvedAccountReturnsOnlyItsBoundCode() {
        for (username in listOf("alice", "alice@gravitas.cool", "@alice:gravitas.cool")) {
            val p = Platform()
            val result = GravitasBroker(p).authorize(challenge, state, username)
            assertEquals("authorized", result["status"])
            assertEquals(setOf("status", "code", "sub", "session_id"), result.keys)
            assertEquals(listOf("t".repeat(43)), p.invalidated)
        }
    }
    @Test fun missingStoreMissingAccountAndDifferentAccountUseTheBrowser() {
        for (p in listOf(Platform().apply { trusted = false }, Platform().apply { available = false }, Platform().apply { names = emptyList() }, Platform().apply { names = listOf("@alice:gravitas.cool", "@bob:gravitas.cool") })) {
            assertEquals("browser", GravitasBroker(p).authorize(challenge, state, "alice")["status"])
            assertEquals(0, p.requests)
        }
        val p = Platform()
        assertEquals("browser", GravitasBroker(p).authorize(challenge, state, "bob")["status"])
        assertEquals("browser", GravitasBroker(p).authorize(challenge, state, "alice@other.example")["status"])
        assertEquals(0, p.requests)
    }
    @Test fun mismatchedResultsNeverReachTheBackend() {
        for (key in listOf("state", "codeChallenge", "issuer", "appOrigin", "redirectUri", "accountName", "accountType", "sessionId")) {
            val p = Platform()
            p.response[key] = "wrong"
            assertEquals(key, "browser", GravitasBroker(p).authorize(challenge, state, "alice")["status"])
            assertEquals(1, p.invalidated.size)
        }
        val p = Platform().apply { response["intent"] = true }
        assertEquals("browser", GravitasBroker(p).authorize(challenge, state, "alice")["status"])
    }
    @Test fun cancellationDoesNotStartBrowserSignIn() {
        val p = Platform().apply { response["errorCode"] = 4 }
        assertEquals("cancelled", GravitasBroker(p).authorize(challenge, state, "alice")["status"])
    }
}
