package app.halo.cloud

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** An in-memory Realtime Database: same surface as the real client, no network. */
class FakeRtdb(override val uid: String = "uid-1") : Rtdb {
    private val root = LinkedHashMap<String, Any?>()
    private class Obs(val path: List<String>, val cb: (String, JsonElement?) -> Unit, @Volatile var open: Boolean = true)
    private val observers = ArrayList<Obs>()
    /** Set to make every write throw — models a dropped connection. */
    @Volatile var failWrites: ((String) -> Boolean)? = null
    /** What a failing write throws: NETWORK by default; OPERATION_FAILED models the server refusing one particular row. */
    @Volatile var failKind: RtdbException.Kind = RtdbException.Kind.NETWORK
    val writes = ArrayList<String>()

    private fun parts(p: String) = p.split('/').filter { it.isNotEmpty() }

    @Suppress("UNCHECKED_CAST")
    private fun node(path: List<String>): Any? {
        var cur: Any? = root
        for (p in path) cur = (cur as? Map<String, Any?>)?.get(p) ?: return null
        return cur
    }

    @Synchronized override fun get(path: String): JsonElement? = StreamModel.toJson(node(parts(path)))

    @Synchronized override fun put(path: String, value: JsonElement) {
        if (failWrites?.invoke(path) == true) throw RtdbException(failKind, "offline")
        writes.add(path)
        val p = parts(path)
        // Which observed child is new?
        val fire = observers.filter { it.open && p.size > it.path.size && p.subList(0, it.path.size) == it.path && node(it.path + p[it.path.size]) == null }
        setNode(p, value)
        for (o in fire) o.cb(p[o.path.size], StreamModel.toJson(node(o.path + p[o.path.size])))
    }

    @Synchronized override fun patch(path: String, value: JsonObject) { for ((k, v) in value) put("$path/$k", v) }

    @Synchronized override fun delete(path: String) {
        if (failWrites?.invoke(path) == true) throw RtdbException(RtdbException.Kind.NETWORK, "offline")
        writes.add("DELETE $path")
        setNode(parts(path), JsonNull)
    }

    @Synchronized override fun shallowKeys(path: String): Set<String> = ((node(parts(path)) as? Map<*, *>)?.keys?.map { it as String }?.toSet()) ?: emptySet()

    @Synchronized override fun observeChildAdded(path: String, onChild: (String, JsonElement?) -> Unit): AutoCloseable {
        val o = Obs(parts(path), onChild); observers.add(o)
        ((node(o.path) as? Map<*, *>)?.keys?.map { it as String }?.sorted() ?: emptyList()).forEach { k -> onChild(k, StreamModel.toJson(node(o.path + k))) }
        return AutoCloseable { o.open = false }
    }

    @Suppress("UNCHECKED_CAST")
    private fun setNode(p: List<String>, value: JsonElement) {
        fun explode(v: JsonElement): Any? = if (v is JsonObject) LinkedHashMap<String, Any?>().also { m -> v.forEach { (k, x) -> m[k] = explode(x) } } else v
        if (p.isEmpty()) { root.clear(); (value as? JsonObject)?.forEach { (k, v) -> root[k] = explode(v) }; return }
        var cur = root
        for (seg in p.dropLast(1)) cur = cur.getOrPut(seg) { LinkedHashMap<String, Any?>() } as LinkedHashMap<String, Any?>
        if (value is JsonNull) cur.remove(p.last()) else cur[p.last()] = explode(value)
    }

    fun dump(path: String): JsonElement? = get(path)
}

fun testCrypto(): CryptoService = CryptoService.create("correct horse battery staple", ByteArray(16) { it.toByte() }, CryptoService.MINIMUM_ITERATIONS)

fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content
