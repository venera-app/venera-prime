package com.github.wgh136.venera

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Base64
import java.io.File
import java.io.FileNotFoundException

/** Disposable integration fixture: opaque IDs, unknown dates and pipe reads. */
class TestDocumentsProvider : DocumentsProvider() {
    private val storage get() = File(context!!.filesDir, "provider-fixture").apply { mkdirs() }
    override fun onCreate() = true
    private fun id(file: File): String = if (file == storage) "root" else "opaque-" +
        Base64.encodeToString(file.relativeTo(storage).path.toByteArray(), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun file(id: String): File {
        if (File(context!!.filesDir, "provider-offline").exists()) throw FileNotFoundException("Fixture offline")
        val result = if (id == "root") storage else File(storage, String(Base64.decode(id.removePrefix("opaque-"), Base64.URL_SAFE)))
        if (result.canonicalFile != storage.canonicalFile && !result.canonicalPath.startsWith(storage.canonicalPath + "/")) throw FileNotFoundException()
        return result
    }
    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cols = projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES)
        return MatrixCursor(cols).apply {
            val values = mapOf<String, Any>(Root.COLUMN_ROOT_ID to "fixture", Root.COLUMN_DOCUMENT_ID to "root", Root.COLUMN_TITLE to "Prime opaque test storage", Root.COLUMN_FLAGS to (Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD), Root.COLUMN_MIME_TYPES to "*/*")
            addRow(cols.map { values[it] }.toTypedArray())
        }
    }
    private fun columns(projection: Array<out String>?) = projection ?: arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS)
    private fun row(cursor: MatrixCursor, file: File) {
        val values = mapOf<String, Any>(Document.COLUMN_DOCUMENT_ID to id(file), Document.COLUMN_DISPLAY_NAME to file.name,
            Document.COLUMN_MIME_TYPE to if(file.isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream",
            Document.COLUMN_SIZE to file.length(), Document.COLUMN_LAST_MODIFIED to 0L,
            Document.COLUMN_FLAGS to (Document.FLAG_SUPPORTS_DELETE or if(file.isDirectory) Document.FLAG_DIR_SUPPORTS_CREATE else Document.FLAG_SUPPORTS_WRITE))
        cursor.addRow(cursor.columnNames.map { values[it] }.toTypedArray())
    }
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = MatrixCursor(columns(projection)).apply {
        val f = file(documentId)
        if (f.exists()) row(this, f)
    }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor = MatrixCursor(columns(projection)).apply {
        val children = file(parentDocumentId).listFiles() ?: throw FileNotFoundException()
        children.sortedBy { it.name }.forEach { row(this, it) }
    }
    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        if(displayName.contains('/') || displayName == "." || displayName == "..") throw FileNotFoundException()
        val f = File(file(parentDocumentId), displayName)
        if (f.exists()) throw FileNotFoundException("Already exists")
        if(mimeType == Document.MIME_TYPE_DIR) f.mkdir() else f.createNewFile()
        return id(f)
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String) = file(documentId).canonicalPath.startsWith(file(parentDocumentId).canonicalPath + "/")
    override fun deleteDocument(documentId: String) {
        val f = file(documentId)
        if(f == storage || !f.deleteRecursively()) throw FileNotFoundException()
    }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode !in listOf("r", "w", "wt")) throw UnsupportedOperationException("Unsupported mode $mode")
        val f = file(documentId)
        if(mode == "r") {
            val pipe = ParcelFileDescriptor.createPipe()
            Thread {
                try { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { out -> f.inputStream().use { it.copyTo(out) } } }
                catch (_: Exception) { }
            }.start()
            return pipe[0]
        }
        if(f.name == "reject-write.bin") throw FileNotFoundException("Read-only fixture")
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.parseMode(mode))
    }
}
