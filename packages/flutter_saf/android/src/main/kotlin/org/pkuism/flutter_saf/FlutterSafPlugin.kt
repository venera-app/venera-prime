package org.pkuism.flutter_saf

import android.app.Activity
import android.app.Activity.RESULT_OK
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Pair
import androidx.annotation.Keep
import androidx.core.net.toUri
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File


/** FlutterSafPlugin */
class FlutterSafPlugin: FlutterPlugin, MethodCallHandler, PluginRegistry.ActivityResultListener, ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var fileMgr : SAFPathWrapper
  private lateinit var result: Result
  private lateinit var myActivity: Activity

  private val CODE_AUTHORIZE_NEW_DIR = 0x8000

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    fileMgr = SAFPathWrapper(flutterPluginBinding.applicationContext)
    fileMgr.init()
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_saf")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, res: Result) {
    result = res
    when (call.method) {
      "pick" -> {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(
          Intent.FLAG_GRANT_READ_URI_PERMISSION
                  or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                  or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        myActivity.startActivityForResult(intent, CODE_AUTHORIZE_NEW_DIR)
      }
      "getMediaPrefix" -> {
        res.success(fileMgr.mediaTypePrefix)
      }
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    fileMgr.shutdown()
    channel.setMethodCallHandler(null)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if(requestCode == CODE_AUTHORIZE_NEW_DIR) {
      result.success(fileMgr.handleIntentResult(resultCode, data))
      return true
    }
    return false
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    myActivity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    myActivity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivity() { }
  override fun onDetachedFromActivityForConfigChanges() { }
}

class RefCountUri(val uri: Uri) {
  var refCount: Int = 1
}

class SAFPathWrapper(private val myContext: Context) {
  val mediaTypePrefix: String = "android://"
  private val _roots: HashMap<String, Uri> = HashMap()
  private val _uriHandles: HashMap<Uri, Int> = HashMap()
  private var nextHandle = 0
  private val _handles: HashMap<Int, RefCountUri> = HashMap()

  private fun getRootUri(rootId: String): Uri? {
    return _roots.getOrDefault(rootId, null)
  }

  private fun getRootUriByName(path: String): Pair<Int, Uri>? {
    val key = _roots.keys.filter { path == it || path.startsWith("$it/") }
      .maxByOrNull { it.length } ?: return null
    return Pair(key.length, _roots[key]!!)
  }

  private fun child(parent: Uri, name: String): Uri? {
    val uri = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
    val cursor = myContext.contentResolver.query(uri, arrayOf(
      DocumentsContract.Document.COLUMN_DOCUMENT_ID,
      DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
      ?: throw java.io.IOException("Provider did not return children")
    cursor.use { c ->
      while (c.moveToNext()) {
        if (c.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(parent, c.getString(0))
      }
    }
    return null
  }

  private fun resolve(path: String, create: Boolean = false, recursive: Boolean = false,
                      isFile: Boolean = false, type: String = "application/octet-stream"): Uri? {
    val root = getRootUriByName(path) ?: return null
    var current = DocumentsContract.buildDocumentUriUsingTree(root.second, DocumentsContract.getTreeDocumentId(root.second))
    val relative = path.substring(root.first).removePrefix("/")
    if (relative.isEmpty()) return current
    val segments = relative.split("/")
    if (segments.any { it.isEmpty() || it == "." || it == ".." }) return null
    for ((index, name) in segments.withIndex()) {
      val last = index == segments.lastIndex
      val found = child(current, name)
      current = found ?: if (create && (last || recursive)) {
        createFile(current, name, if (last && isFile) type else DocumentsContract.Document.MIME_TYPE_DIR)
          ?: return null
      } else return null
      if ((!last || (create && !isFile)) && getUriMime(current) != DocumentsContract.Document.MIME_TYPE_DIR) return null
      if (last && create && isFile && getUriMime(current) == DocumentsContract.Document.MIME_TYPE_DIR) return null
    }
    return current
  }

  @Keep
  fun statDoc(descriptor: Int): String? {
    val uri = getDocumentUri(descriptor) ?: return null
    try {
      myContext.contentResolver.query(uri, arrayOf(
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
        if (c.moveToFirst()) return org.json.JSONObject().put("directory", c.getString(0) == DocumentsContract.Document.MIME_TYPE_DIR)
          .put("size", if(c.isNull(1)) 0L else c.getLong(1))
          .put("modified", if(c.isNull(2)) 0L else c.getLong(2)).toString()
      }
    } catch (_: Exception) { }
    return null
  }

  //document descriptor:
  //>0: normal documentfile
  // 0: root document
  //-1: invalid document
  //-2: document cache invalid(need refresh your descriptor)
  //-3: this file is accessible through direct path
  enum class SpecialDescriptors(val id: Int) {
    DOC_ROOT(0),
    DOC_INVALID(-1),
    DOC_CACHE_MISS(-2),
    DOC_NORMAL(-3)
  }

  @Synchronized
  private fun getDocumentUri(descriptor: Int): Uri? {
    return _handles.getOrDefault(descriptor, null)?.uri
  }

  @Synchronized
  private fun setDocumentUri(doc: Uri): Int {
    _uriHandles[doc]?.let { existing ->
      _handles[existing]!!.refCount++
      return existing
    }
    do { nextHandle = if (nextHandle == Int.MAX_VALUE) 1 else nextHandle + 1 } while (_handles.containsKey(nextHandle))
    val descriptor = nextHandle
    _handles[descriptor] = RefCountUri(doc)
    _uriHandles[doc] = descriptor
    return descriptor
  }

  @Keep
  @Synchronized
  fun deleteDocumentUri(descriptor: Int) {
    if (_handles.containsKey(descriptor)) {
      val r = --_handles[descriptor]!!.refCount;
      if (r == 0) {
        _uriHandles.remove(_handles[descriptor]!!.uri)
        _handles.remove(descriptor)
      }
    }
  }

  private fun existsUri(uri: Uri): Boolean {
    try {
      myContext.contentResolver.query(
        uri,
        arrayOf<String>(
          DocumentsContract.Document.COLUMN_DOCUMENT_ID
        ),
        null,
        null,
        null
      )?.use { c ->
        return c.count > 0
      }
    } catch (e: Exception) {
      return false
    }
    return false
  }

  private fun createDir(uri: Uri, name: String): Uri? {
    return createFile(uri, name, DocumentsContract.Document.MIME_TYPE_DIR)
  }

  private fun createFile(uri: Uri, name: String, type: String = "application/octet-stream"): Uri? {
    return DocumentsContract.createDocument(myContext.contentResolver, uri, type, name)
  }

  private fun getUriMime(uri: Uri): String {
    myContext.contentResolver.query(
      uri,
      arrayOf<String>(
        DocumentsContract.Document.COLUMN_MIME_TYPE
      ),
      null,
      null,
      null
    )?.use { c ->
      if (c.moveToFirst()) {
        return c.getString(0)
      }
      return ""
    }
    return ""
  }

  private fun geturiFileSize(uri: Uri): Int {
    myContext.contentResolver.query(
      uri,
      arrayOf<String>(
        DocumentsContract.Document.COLUMN_SIZE
      ),
      null,
      null,
      null
    )?.use { c ->
      return if (c.moveToFirst()) c.getInt(0) else 0
    }
    return 0
  }

  private fun getDirChildrenCount(uri: Uri): Int {
    val childUri =
      DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getDocumentId(uri))
    myContext.contentResolver.query(
      childUri,
      arrayOf<String>(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID
      ),
      null,
      null,
      null
    )?.use { c ->
      return c.count
    }
    return 0
  }

  private fun isUriFile(uri: Uri): Boolean {
    val mime = getUriMime(uri)
    return !(DocumentsContract.Document.MIME_TYPE_DIR == mime || mime.isEmpty())
  }

  private fun isUriDir(uri: Uri): Boolean {
    return getUriMime(uri) == DocumentsContract.Document.MIME_TYPE_DIR
  }

  private external fun setupNativeProxy()
  private external fun destroyNativeProxy()

  fun init() {
    System.loadLibrary("flutter-saf")
    setupNativeProxy()
    val permissions = myContext.contentResolver.persistedUriPermissions
    for (p in permissions) {
      updateRoot(p.uri)
    }
  }

  fun shutdown() {
    _handles.clear()
    _uriHandles.clear()
    _roots.clear()
    destroyNativeProxy()
  }

  fun listRoots(): ArrayList<ArrayList<String>> {
    val ret = ArrayList<ArrayList<String>>();
    val dirs = ArrayList<String>();
    val uris = ArrayList<String>();

    for (k in _roots.keys) {
      dirs.add(k)
      uris.add(_roots[k]?.path ?: k)
    }
    ret.add(dirs)
    ret.add(uris)
    return ret
  }

  fun removeRootUri(path: String) {
    val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    myContext.contentResolver.releasePersistableUriPermission(_roots[path]!!, takeFlags)
  }

  fun handleIntentResult(resultCode: Int, data: Intent?):ArrayList<String>? {
    if(resultCode != RESULT_OK) {
      return null
    }
    val pickedDirectoryUri = data?.data ?: return null

    myContext.contentResolver.takePersistableUriPermission(pickedDirectoryUri,
      Intent.FLAG_GRANT_READ_URI_PERMISSION
              or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

    val rootID = updateRoot(pickedDirectoryUri)

    val root = "$mediaTypePrefix$rootID"
    val info = ArrayList<String>()
    info.add(root)
    info.add(onOpenPath(root).toString())

    return info
  }

  private fun updateRoot(uri: Uri): String {
    val id = "tree:" + android.util.Base64.encodeToString(uri.toString().toByteArray(Charsets.UTF_8),
      android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING)
    _roots[id] = uri
    // Retain old local-storage paths; new paths include the authority and tree URI.
    if (uri.authority == "com.android.externalstorage.documents") {
      _roots[DocumentsContract.getTreeDocumentId(uri)] = uri
    }
    return id
  }

  //Handle
  //Path is like $mediaPrefixprimary:comic/bar/foo/text.png
  //                        | treedoc.id |  normalPath
  //root directory's descriptor will be nothing
  //Cache DocumentFile to gain better performance
  //both dir and file uses this function
  @Keep
  fun onOpenPath(p: String): Int {
    if (!p.startsWith(mediaTypePrefix)) {
      return SpecialDescriptors.DOC_NORMAL.id
    }

    val path = p.substring(mediaTypePrefix.length)

    if (path == "") {
      return SpecialDescriptors.DOC_ROOT.id
    }

    try {
      val target = resolve(path) ?: return SpecialDescriptors.DOC_INVALID.id
      return if (existsUri(target)) setDocumentUri(target) else SpecialDescriptors.DOC_INVALID.id
    } catch (e1: Exception) {
      return SpecialDescriptors.DOC_INVALID.id
    }
  }

  @Keep
  fun getParent(descriptor: Int): Int {
    if(descriptor > 0) {
      val df = getDocumentUri(descriptor) ?: return SpecialDescriptors.DOC_CACHE_MISS.id

      val pf = DocumentFile.fromTreeUri(myContext, df)?.parentFile
        ?: return SpecialDescriptors.DOC_ROOT.id//root
      return setDocumentUri(pf.uri)
    }
    return SpecialDescriptors.DOC_INVALID.id
  }

  @Keep
  @JvmOverloads
  fun createDirectory(
    p: String,
    recursive: Boolean,
    isFile: Boolean = false,
    type: String = "application/octet-stream"
  ): Int {
    //root directory can't create new directory

    if (!p.startsWith(mediaTypePrefix)) {
      return SpecialDescriptors.DOC_NORMAL.id
    }

    val path = p.substring(mediaTypePrefix.length)

    if (path.isEmpty()) {
      return SpecialDescriptors.DOC_INVALID.id
    }

    return try {
      val target = resolve(path, true, recursive, isFile, type)
        ?: return SpecialDescriptors.DOC_INVALID.id
      setDocumentUri(target)
    } catch (_: Exception) { SpecialDescriptors.DOC_INVALID.id }
  }

  fun _list(root: Uri): Pair<Pair<String, IntArray>, Pair<String, IntArray>>? {
    try {
      val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
        root,
        DocumentsContract.getDocumentId(root)
      )
      myContext.contentResolver.query(
        childrenUri,
        arrayOf(
          DocumentsContract.Document.COLUMN_DISPLAY_NAME,
          DocumentsContract.Document.COLUMN_MIME_TYPE,
          DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        ),
        null,
        null,
        null
      )?.use { q ->
        val dirList = StringBuilder()
        val fileList = StringBuilder()
        val dirDescriptors = ArrayList<Int>()
        val fileDescriptors = ArrayList<Int>()
        while (q.moveToNext()) {
          val name = q.getString(0)
          if (name.isNullOrEmpty() || name == "." || name == ".." || name.contains("/")) throw java.io.IOException("Invalid document name")
          val mime = q.getString(1)
          val docId = q.getString(2)
          if (mime.equals(DocumentsContract.Document.MIME_TYPE_DIR)) {
            dirList.append("${Uri.encode(name)}|")
            dirDescriptors.add(
              setDocumentUri(
                DocumentsContract.buildDocumentUriUsingTree(
                  root,
                  docId
                )
              )
            )
          } else {
            fileList.append("${Uri.encode(name)}|")
            fileDescriptors.add(
              setDocumentUri(
                DocumentsContract.buildDocumentUriUsingTree(
                  root,
                  docId
                )
              )
            )
          }
        }
        if (dirList.lastIndex != -1) {
          dirList.deleteCharAt(dirList.lastIndex)
        }
        if (fileList.lastIndex != -1) {
          fileList.deleteCharAt(fileList.lastIndex)
        }
        return Pair(
          Pair(dirList.toString(), dirDescriptors.toIntArray()),
          Pair(fileList.toString(), fileDescriptors.toIntArray())
        )
      }
    } catch (e: Exception) {
      return null
    }
    return null
  }

  @Keep
  fun listDirectory(descriptor: Int): Pair<Pair<String, IntArray>, Pair<String, IntArray>>? {
    if (descriptor == SpecialDescriptors.DOC_ROOT.id) {
      //root directory, list all authorized directories
      return Pair(
        Pair(
          java.lang.String.join("|", _roots.keys.map { Uri.encode(it) }),
          _roots.values.map { v -> setDocumentUri(DocumentsContract.buildDocumentUriUsingTree(v, DocumentsContract.getTreeDocumentId(v))) }.toIntArray()
        ), Pair("", intArrayOf())
      )
    }

    if (descriptor < 0) {
      return null
    }
    try {
      val root = getDocumentUri(descriptor)
      if (root != null) {
        return _list(root)
      }
      return null
    } catch (e: SecurityException) {
      return null
    }
  }

  // 0 root dir(currently can't copy)
  //-1 invalid source dir
  //-2 cache miss
  //-3 success but dest is a normal dir
  //-4 dest is a file
  //-5 dest is not an empty folder
  //-6 copy process was interrupted
  @Keep
  fun renameDirectory(descriptor: Int, newPath: String): Int {
    try {
    if(descriptor <= 0) {
      return descriptor
    }

    val src = getDocumentUri(descriptor) ?: return -2
    var dstInfo = onOpenPath(newPath)
    val dstFile: Uri
    if (dstInfo == SpecialDescriptors.DOC_NORMAL.id) {

      dstFile = File(newPath).toUri()

    } else if (dstInfo == SpecialDescriptors.DOC_INVALID.id) {

      dstInfo = createDirectory(newPath, true)
      dstFile = getDocumentUri(dstInfo)!!

    } else {
      dstFile = getDocumentUri(dstInfo)!!
      if (isUriFile(dstFile)) {
        return -4
      }
      if (isUriDir(dstFile) && getDirChildrenCount(dstFile) > 0) {
        return -5
      }
    }

    //no error
    var flag = true

    fun copyDir(src: Uri, dst: Uri) {
      val srcChild =
        DocumentsContract.buildChildDocumentsUriUsingTree(src, DocumentsContract.getDocumentId(src))
      myContext.contentResolver.query(
        srcChild,
        arrayOf<String>(
          DocumentsContract.Document.COLUMN_DISPLAY_NAME,
          DocumentsContract.Document.COLUMN_MIME_TYPE,
          DocumentsContract.Document.COLUMN_DOCUMENT_ID
        ),
        null,
        null,
        null
      )?.use { c ->
          while (c.moveToNext()) {
            val sf = DocumentsContract.buildDocumentUriUsingTree(src, c.getString(2))
            if (isUriFile(sf)) {
              val sft = c.getString(1).ifEmpty { "application/octet-stream" }
              val df = createFile(dst, c.getString(0), sft)
              val sfs = myContext.contentResolver.openInputStream(sf)!!
              val dfs = myContext.contentResolver.openOutputStream(df!!)!!
              sfs.copyTo(dfs)
              dfs.close()
              sfs.close()
            } else {
              val dd = createDir(dst, c.getString(0))!!
              copyDir(sf, dd)
            }
          }
      }
    }

    try {
      //DocumentsContract.copyDocument(myContext.contentResolver, src, dstFile)
      copyDir(src, dstFile)
    } catch (e : Exception) {
      flag = false
    }

    if(flag) {
      DocumentsContract.deleteDocument(myContext.contentResolver, src)
      return dstInfo
    } else {
      DocumentsContract.deleteDocument(myContext.contentResolver, dstFile)
      return -6
    }
    } catch (_: Exception) { return -6 }
  }

  // 0 root dir(currently can't copy)
  //-1 invalid source dir
  //-2 cache miss
  //-3 success but dest is a normal file
  //-4 dest is present
  //-5 copy process was interrupted
  @Keep
  fun renameFile(descriptor: Int, newPath: String, copy: Boolean): Int {
    try {
    if(descriptor <= 0) {
      return descriptor
    }

    val src = getDocumentUri(descriptor) ?: return -2
    var dstInfo = onOpenPath(newPath)
    val dstFile: Uri
    if (dstInfo == SpecialDescriptors.DOC_NORMAL.id) {
      dstFile = File(newPath).toUri()
    } else if (dstInfo == SpecialDescriptors.DOC_INVALID.id) {
      dstInfo = createDirectory(
        newPath,
        recursive = true,
        isFile = true,
        type = getUriMime(src).ifEmpty { "application/octet-stream" })
      dstFile = getDocumentUri(dstInfo)!!
    } else {
      return -4
    }

    //no error
    var flag = true

    try {
      myContext.contentResolver.openInputStream(src)!!.use { input ->
        myContext.contentResolver.openOutputStream(dstFile)!!.use { output -> input.copyTo(output) }
      }
    } catch (e : Exception) {
      flag = false
    }

    if(flag) {
      if(!copy) {
        DocumentsContract.deleteDocument(myContext.contentResolver, src)
      }
      return dstInfo
    } else {
      DocumentsContract.deleteDocument(myContext.contentResolver, dstFile)
      return -5
    }
    } catch (_: Exception) { return -5 }
  }

  // 0 success
  //-1 cannot delete root or invalid folder
  //-2 cache miss(impossible)
  //-3 directory is not empty but recursive is false
  @Keep
  fun deleteDir(descriptor: Int, recursive: Boolean): Int {
    if(descriptor <= 0) {
      return -1
    }
    return try {
    val root = getDocumentUri(descriptor) ?: return -2

    val content = getDirChildrenCount(root)
    if (content > 0) {
      if(!recursive) {
        return -3
      }
    }
    if (!DocumentsContract.deleteDocument(myContext.contentResolver, root)) {
      return -1
    }
    0
    } catch (_: Exception) { -1 }
  }

  @Keep
  fun deleteFile(descriptor: Int): Int {
    if(descriptor <= 0) {
      return -1
    }
    return try {
    val root = getDocumentUri(descriptor) ?: return -2
    if (!DocumentsContract.deleteDocument(myContext.contentResolver, root)) {
      return -1
    }
    0
    } catch (_: Exception) { -1 }
  }

  @Keep
  fun getFileSize(descriptor: Int): Int {
    if(descriptor <= 0) {
      return 0
    }
    val doc = getDocumentUri(descriptor) ?: return 0
    return try { if (isUriFile(doc)) geturiFileSize(doc) else 0 } catch (_: Exception) { -1 }
  }

  //returning a descriptor to cpp or an error code
  //-1 file not exist
  //-2 permission denied
  //-3 unknown error
  @Keep
  fun fopen(descriptor: Int, mode: String): Int {
    if(descriptor <= 0) {
      return -1
    }
    val doc = getDocumentUri(descriptor) ?: return -1
    return try {
      val pfd = try {
        myContext.contentResolver.openFileDescriptor(doc, mode)
      } catch (e: UnsupportedOperationException) {
        // Cloud providers (including webdav-provider) may only expose write-only
        // handles. Keep native/read-write support when it is available.
        if (mode != "rwt") throw e
        myContext.contentResolver.openFileDescriptor(doc, "wt")
      }
      pfd?.detachFd() ?: -2
    } catch (e: Exception) {
      -2
    }
  }
}
