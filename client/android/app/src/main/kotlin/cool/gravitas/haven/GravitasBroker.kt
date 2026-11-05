package cool.gravitas.haven

internal object BrokerProtocol {
    const val PACKAGE = "dev.jeeth.privatestore"
    const val CERTIFICATE = "e70b5b54a0d174f4ad8867889f6481a2b193dc9c130630f321563e12f3293793"
    const val ACCOUNT_TYPE = "dev.jeeth.privatestore.gravitas"
    const val ORIGIN = "https://haven.gravitas.cool"
    const val ISSUER = "https://gravitas.cool"
    const val REDIRECT = "$ORIGIN/auth/gravitas/callback"
    private val proof = Regex("[A-Za-z0-9_-]{43}")
    fun tokenType(challenge: String, state: String): String {
        require(proof.matches(challenge) && proof.matches(state))
        return "gravitas_code:haven:v1:$challenge:$state"
    }
    fun trusted(packageName: String, type: String, signers: List<String>) =
        packageName == PACKAGE && type == ACCOUNT_TYPE && signers == listOf(CERTIFICATE)
}

internal interface BrokerPlatform {
    fun trusted(): Boolean
    fun prepare(): Boolean
    fun accounts(): List<String>
    fun request(account: String, type: String, challenge: String, state: String): Map<String, Any?>
    fun invalidate(code: String)
}

/** No passwords or store credentials cross this interface. No provider intents are started. */
internal class GravitasBroker(private val platform: BrokerPlatform) {
    fun authorize(challenge: String, state: String, username: String?): Map<String, Any?> {
        val browser = mapOf("status" to "browser")
        return try {
            val type = BrokerProtocol.tokenType(challenge, state)
            if (!platform.trusted() || !platform.prepare()) return browser
            val accounts = platform.accounts()
            if (accounts.size != 1) return browser
            val account = accounts.single()
            if (!account.matches(Regex("@[a-z0-9]{1,20}:gravitas\\.cool"))) return browser
            if (!username.isNullOrBlank()) {
                var expected = username.trim().lowercase().removePrefix("@")
                expected = if (expected.contains(':')) "@$expected"
                    else if (expected.contains('@')) "@" + expected.replace('@', ':')
                    else "@$expected:gravitas.cool"
                if (expected != account) return browser
            }
            val response = platform.request(account, type, challenge, state)
            val code = response["authtoken"] as? String
            if (!code.isNullOrEmpty()) platform.invalidate(code)
            if (response["intent"] == true) return browser
            when (response["errorCode"] ?: 0) {
                4 -> return mapOf("status" to "cancelled")
                3 -> return mapOf("status" to "unavailable")
                6, 9 -> return browser
                0 -> {}
                else -> return browser
            }
            require(response["protocolVersion"] == 1 && response["state"] == state && response["codeChallenge"] == challenge)
            require(response["issuer"] == BrokerProtocol.ISSUER && response["appOrigin"] == BrokerProtocol.ORIGIN && response["redirectUri"] == BrokerProtocol.REDIRECT)
            require(response["accountType"] == BrokerProtocol.ACCOUNT_TYPE && response["accountName"] == account)
            require(!code.isNullOrBlank() && code.length in 32..2048 && code.none { it.isWhitespace() })
            val subject = response["subject"] as? String ?: error("missing subject")
            val family = response["sessionId"] as? String ?: error("missing family")
            require(subject.length in 1..256 && family.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")))
            mapOf("status" to "authorized", "code" to code, "sub" to subject, "session_id" to family)
        } catch (_: java.io.IOException) { mapOf("status" to "unavailable") }
          catch (_: Exception) { browser }
    }
}
