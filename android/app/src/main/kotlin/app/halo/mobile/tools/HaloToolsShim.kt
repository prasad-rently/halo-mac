package app.halo.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.halo.mobile.Halo

/*
 * Two adapters over app.halo.mobile.design (feat/v2.6-m-android-design). Everything else in the Tools screens uses the design
 * system's components directly. These exist only because the design system's versions have a different shape:
 *  - HaloChip: design's takes (text, modifier, selected, ...) and has no disabled state; the transform chips need one.
 *  - ToolMetricTile: design's HaloMetricTile requires an icon and a String value; a speed result needs "—" for "not measured" and a unit.
 */
@Composable
fun HaloChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    app.halo.mobile.design.HaloChip(label, modifier.alpha(if (enabled) 1f else 0.4f), selected = selected, onClick = if (enabled) onClick else null)
}

@Composable
fun HaloMetricTile(label: String, value: String?, unit: String, modifier: Modifier = Modifier, accent: Color = Halo.Text) {
    Column(modifier.clip(RoundedCornerShape(14.dp)).background(Halo.Surface).padding(14.dp)) {
        Text(label.uppercase(), color = Halo.Text3, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.2.sp)
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value ?: "—", color = if (value == null) Halo.Text3 else accent, fontSize = 28.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            if (value != null) Text(" $unit", color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.padding(bottom = 5.dp))
        }
    }
}
