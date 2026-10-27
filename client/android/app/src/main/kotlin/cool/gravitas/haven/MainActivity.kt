package cool.gravitas.haven

import android.Manifest
import android.content.ContentUris
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var asked = false
    private val requestCode = 4181

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "cool.gravitas.haven/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listMedia" -> {
                        if (pending != null) { result.error("busy", "Permission request in progress", null) }
                        else if (!hasAnyAccess() && !asked) {
                            asked = true; pending = result
                            val permissions = if (Build.VERSION.SDK_INT >= 34) arrayOf(
                                Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                                Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                            else if (Build.VERSION.SDK_INT >= 33) arrayOf(
                                Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                                Manifest.permission.READ_MEDIA_AUDIO)
                            else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
                            requestPermissions(permissions, requestCode)
                        } else discover(result)
                    }
                    "readChunk" -> execute(result) {
                        val uri = mediaUri(call.argument<String>("uri"))
                        val offset = call.argument<Number>("offset")!!.toLong()
                        val length = call.argument<Number>("length")!!.toInt()
                        require(offset >= 0 && length in 0..1048576)
                        contentResolver.openFileDescriptor(uri, "r")!!.use { descriptor ->
                            FileInputStream(descriptor.fileDescriptor).use { stream ->
                                stream.channel.position(offset)
                                val bytes = ByteArray(length); var count = 0
                                while (count < length) { val n = stream.read(bytes, count, length-count); if (n < 0) break; count += n }
                                bytes.copyOf(count)
                            }
                        }
                    }
                    "thumbnail" -> execute(result) {
                        val uri = mediaUri(call.argument<String>("uri"))
                        val bitmap = if (Build.VERSION.SDK_INT >= 29) contentResolver.loadThumbnail(uri, Size(384,384),null)
                        else {
                            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                            contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it,null,options) }
                            var sample=1; while(options.outWidth/sample>384 || options.outHeight/sample>384) sample*=2
                            options.inJustDecodeBounds=false; options.inSampleSize=sample
                            contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it,null,options) }
                        } ?: error("Thumbnail unavailable")
                        val out=ByteArrayOutputStream();bitmap.compress(Bitmap.CompressFormat.JPEG,70,out);bitmap.recycle()
                        out.toByteArray().also { require(it.size <= 131072) }
                    }
                    else -> result.notImplemented()
                }
            }
    }
    private fun mediaUri(value:String?):Uri {
        val uri=Uri.parse(value ?: error("Missing media URI"))
        require(uri.scheme=="content" && uri.authority=="media")
        return uri
    }
    private fun granted(permission:String) = checkSelfPermission(permission)==PackageManager.PERMISSION_GRANTED
    private fun hasAnyAccess():Boolean = if(Build.VERSION.SDK_INT>=33) {
        granted(Manifest.permission.READ_MEDIA_IMAGES)||granted(Manifest.permission.READ_MEDIA_VIDEO)||
            granted(Manifest.permission.READ_MEDIA_AUDIO)||(Build.VERSION.SDK_INT>=34&&granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
    } else granted(Manifest.permission.READ_EXTERNAL_STORAGE)
    private fun execute(result:MethodChannel.Result,action:()->Any?) {
        worker.execute {
            try { val value=action();runOnUiThread {result.success(value)} }
            catch (e:Exception) {runOnUiThread {result.error("media_error",e.message,null)}}
        }
    }
    private fun discover(result:MethodChannel.Result) = execute(result) {
        check(hasAnyAccess()) {"Allow gallery access in Android settings to back up media."}
        val entries=mutableListOf<Map<String,Any>>()
        val limited=Build.VERSION.SDK_INT>=34&&granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        val collections=listOf(
            Triple(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, Manifest.permission.READ_MEDIA_IMAGES, true),
            Triple(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, Manifest.permission.READ_MEDIA_VIDEO, true),
            Triple(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, Manifest.permission.READ_MEDIA_AUDIO, false))
        for((collection,permission,visual) in collections) {
            if(Build.VERSION.SDK_INT>=33&&!granted(permission)&&!(limited&&visual))continue
            val projection=arrayOf(MediaStore.MediaColumns._ID,MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.MIME_TYPE,MediaStore.MediaColumns.SIZE,MediaStore.MediaColumns.DATE_MODIFIED,MediaStore.MediaColumns.DATE_ADDED)
            contentResolver.query(collection,projection,null,null,"${MediaStore.MediaColumns._ID} ASC")?.use { cursor ->
                while(cursor.moveToNext()) {
                    val id=cursor.getLong(0);val size=cursor.getLong(3);if(size<0)continue
                    entries.add(mapOf("ref" to ContentUris.withAppendedId(collection,id).toString(),
                        "name" to (cursor.getString(1)?:"media-$id"),"mime" to (cursor.getString(2)?:"application/octet-stream"),
                        "size" to size,"modified" to cursor.getLong(4),"captured" to cursor.getLong(5)))
                }
            }
        };entries
    }
    override fun onRequestPermissionsResult(code:Int,permissions:Array<out String>,results:IntArray) {
        super.onRequestPermissionsResult(code,permissions,results)
        if(code==requestCode){val result=pending;pending=null;if(result!=null)discover(result)}
    }
    override fun onDestroy(){worker.shutdown();super.onDestroy()}
}
