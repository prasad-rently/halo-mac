package app.halo.tools

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The desktop <-> phone cross-check. docs/specs/text-transform-vectors.v1.json was PRODUCED by running the desktop actions'
 * own shell pipelines (android/tools/gen-transform-vectors.py), so passing means the phone prints what the Mac prints — it
 * is not Kotlin agreeing with itself.
 */
class TransformVectorsTest {
    private val doc: JsonObject = Json.parseToJsonElement(File(System.getProperty("halo.transformVectors")!!).readText()).jsonObject
    private val ids = mapOf(
        "format_json" to TransformId.FORMAT_JSON, "minify_json" to TransformId.MINIFY_JSON, "count_words" to TransformId.COUNT_WORDS,
        "sort_lines" to TransformId.SORT_LINES, "url_encode" to TransformId.URL_ENCODE, "url_decode" to TransformId.URL_DECODE,
        "base64_encode" to TransformId.BASE64_ENCODE, "base64_decode" to TransformId.BASE64_DECODE, "uppercase" to TransformId.UPPERCASE,
        "lowercase" to TransformId.LOWERCASE, "dedup_lines" to TransformId.DEDUP_LINES, "strip_formatting" to TransformId.STRIP_FORMATTING,
        "sha256" to TransformId.SHA256,
    )

    @Test fun everyDesktopVectorMatches() {
        val cases = doc["cases"]!!.jsonArray
        assertTrue("fixture should be substantial", cases.size >= 60)
        val seen = mutableSetOf<String>()
        for (c in cases) {
            val o = c.jsonObject
            val key = o["transform"]!!.jsonPrimitive.content; seen += key
            val input = o["input"]!!.jsonPrimitive.content
            val expected = o["expected"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.content }
            val id = ids.getValue(key)
            val got = TextTransforms.apply(id, input)
            val label = "${o["id"]!!.jsonPrimitive.content} ($key)"
            if (expected == null) { assertTrue("$label should fail like the desktop: $got", got is TransformResult.Failure); continue }
            val text = when (got) {
                is TransformResult.Output -> if (id == TransformId.COUNT_WORDS) TextStats.of(input).desktopFormat() else got.text
                else -> throw AssertionError("$label: expected output, got $got")
            }
            assertEquals(label, expected, text)
        }
        assertEquals("every transform in the catalog that has a desktop script is covered", ids.keys, seen)
    }

    @Test fun generatorShapesMatchTheFixtureProperties() {
        val props = doc["properties"]!!.jsonObject
        repeat(50) {
            assertTrue(Regex(props["uuid"]!!.jsonPrimitive.content).matches(TextTransforms.uuid()))
            assertTrue(Regex(props["password"]!!.jsonPrimitive.content).matches(TextTransforms.password()))
        }
    }
}
