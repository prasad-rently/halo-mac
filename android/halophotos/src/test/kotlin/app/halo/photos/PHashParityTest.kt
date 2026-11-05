package app.halo.photos

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Cross-language parity: the hashes in docs/specs/phash-parity.v1.json were produced by the real SWIFT DCT/median code
 * (scripts/phash-parity-swift.swift, drift-checked against Halo/Core/Scanner/PerceptualDuplicateDetector.swift).
 * This asserts the Kotlin port reproduces them — hash AND all 64 coefficients, so a constant that rescales every
 * coefficient equally (which leaves the bits untouched) is still caught.
 */
class PHashParityTest {
    private val cases: List<JsonObject> by lazy {
        val f = File(System.getProperty("halo.phashParity") ?: error("halo.phashParity not set"))
        Json.parseToJsonElement(f.readText()).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }
    }

    private fun px(c: JsonObject) = c["pixels"]!!.jsonArray.map { it.jsonPrimitive.int }.toIntArray()
    private fun robust(c: JsonObject) = !c["degenerate"]!!.jsonPrimitive.boolean

    @Test fun `fixture is substantial and its asserted cases are numerically robust`() {
        val r = cases.filter(::robust)
        assertTrue("need >= 30 robust cases, have ${r.size}", r.size >= 30)
        // A margin this far above rounding noise (1e-13) means no libm difference can flip any asserted bit.
        r.forEach { assertTrue("${it["name"]} margin ${it["margin"]}", it["margin"]!!.jsonPrimitive.double > 1e-6) }
    }

    @Test fun `kotlin hash equals the Swift hash for every robust case`() {
        for (c in cases.filter(::robust)) {
            val expected = c["hash"]!!.jsonPrimitive.content.toULong(16).toLong()
            val got = PHash.hash(px(c))
            assertEquals("${c["name"]}: swift=%016x kotlin=%016x".format(expected, got), expected, got)
        }
    }

    @Test fun `kotlin coefficients equal the Swift coefficients`() {
        for (c in cases.filter(::robust)) {
            val expected = (c["coefficients"] as JsonArray).map { it.jsonPrimitive.double }
            val got = PHash.lowFrequency(DoubleArray(1024) { px(c)[it].toDouble() })
            for (i in 0 until 64) {
                val tol = 1e-9 * maxOf(1.0, Math.abs(expected[i]))
                assertEquals("${c["name"]} coefficient $i", expected[i], got[i], tol)
            }
        }
    }

    @Test fun `degenerate cases - informational, bits are rounding noise so they are not asserted`() {
        val d = cases.filter { !robust(it) }
        val same = d.count { it["hash"]!!.jsonPrimitive.content.toULong(16).toLong() == PHash.hash(px(it)) }
        println("pHash parity: ${cases.size - d.size} robust cases asserted bit-exact; degenerate (symmetric/flat) cases matching Swift anyway: $same/${d.size}")
        // The one property that must hold regardless of noise: a flat black image has all-equal coefficients -> no bit above the median.
        val flat0 = cases.first { it["name"]!!.jsonPrimitive.content == "flat-0" }
        assertEquals(0L, PHash.hash(px(flat0)))
    }
}
