package cool.gravitas.haven

import android.accounts.Account
import android.accounts.AccountManager
import android.accounts.OperationCanceledException
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

internal class AndroidBrokerPlatform(private val context: Context) : BrokerPlatform {
    private val accounts = AccountManager.get(context)
    @Suppress("DEPRECATION")
    override fun trusted(): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val manager = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val info = try { manager.getPackageInfo(BrokerProtocol.PACKAGE, flags) }
            catch (_: PackageManager.NameNotFoundException) { return false }
        if (info.applicationInfo?.enabled != true) return false
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        val digests = signatures?.map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) } } ?: return false
        val authenticators = accounts.authenticatorTypes.filter { it.type == BrokerProtocol.ACCOUNT_TYPE }
        val provider = manager.resolveContentProvider(BrokerProtocol.ACCOUNT_TYPE, 0) ?: return false
        return provider.packageName == BrokerProtocol.PACKAGE && provider.enabled && provider.exported &&
            authenticators.size == 1 && BrokerProtocol.trusted(authenticators.single().packageName, authenticators.single().type, digests)
    }
    override fun prepare(): Boolean {
        val response = context.contentResolver.call(Uri.parse("content://${BrokerProtocol.ACCOUNT_TYPE}"), "prepare", null, null) ?: return false
        return response.getInt("protocolVersion") == 1 && response.getBoolean("available")
    }
    override fun accounts() = accounts.getAccountsByType(BrokerProtocol.ACCOUNT_TYPE).map { it.name }
    override fun request(account: String, type: String, challenge: String, state: String): Map<String, Any?> {
        val options = Bundle().apply { putInt("protocolVersion", 1); putString("codeChallenge", challenge); putString("state", state) }
        val pending = accounts.getAuthToken(Account(account, BrokerProtocol.ACCOUNT_TYPE), type, options, false, null, null)
        return try {
            val result = pending.getResult(20, TimeUnit.SECONDS)
            mutableMapOf<String, Any?>(
                "authtoken" to result.getString(AccountManager.KEY_AUTHTOKEN),
                "accountName" to result.getString(AccountManager.KEY_ACCOUNT_NAME),
                "accountType" to result.getString(AccountManager.KEY_ACCOUNT_TYPE),
                "intent" to result.containsKey(AccountManager.KEY_INTENT),
                "errorCode" to result.getInt(AccountManager.KEY_ERROR_CODE, 0),
                "protocolVersion" to result.getInt("protocolVersion", 0),
            ).apply { for (key in listOf("state", "codeChallenge", "issuer", "appOrigin", "redirectUri", "subject", "sessionId")) put(key, result.getString(key)) }
        } catch (_: OperationCanceledException) { mapOf("errorCode" to AccountManager.ERROR_CODE_CANCELED) }
        finally { if (!pending.isDone) pending.cancel(true) }
    }
    override fun invalidate(code: String) { accounts.invalidateAuthToken(BrokerProtocol.ACCOUNT_TYPE, code) }
}
