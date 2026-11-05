package app.halo.tools

/** One of the desktop Code Beautifier's eight themes (generated from CodeTheme.swift — same hex values). Colours are 0xAARRGGBB. */
data class CodeTheme(
    val id: String, val name: String, val backgroundFrom: Long, val backgroundTo: Long, val foreground: Long, val keyword: Long,
    val string: Long, val comment: Long, val function: Long, val number: Long, val type: Long, val operator: Long, val lineNumber: Long,
) {
    fun color(t: TokenType): Long = when (t) {
        TokenType.PLAIN -> foreground; TokenType.KEYWORD -> keyword; TokenType.STRING -> string; TokenType.COMMENT -> comment
        TokenType.FUNCTION -> function; TokenType.NUMBER -> number; TokenType.TYPE -> type; TokenType.OPERATOR -> operator
    }

    companion object {
        val all: List<CodeTheme> = listOf(
            CodeTheme("midnight", "Midnight", 0xFF0D1220, 0xFF131928, 0xFFE2E8F0, 0xFF4F7CFF, 0xFF22D97A, 0xFF4A5568, 0xFFF5A623, 0xFFF59E0B, 0xFF00D4E8, 0xFFB06CFF, 0xFF374151),
            CodeTheme("noir", "Noir", 0xFF000000, 0xFF0A0A0A, 0xFFD4D4D4, 0xFFC792EA, 0xFFC3E88D, 0xFF545454, 0xFF82AAFF, 0xFFF78C6C, 0xFFFFCB6B, 0xFF89DDFF, 0xFF333333),
            CodeTheme("aurora", "Aurora", 0xFF0B1A0B, 0xFF0D2818, 0xFFD4EDDA, 0xFF22D97A, 0xFF00D4E8, 0xFF3A5A3A, 0xFF82FFA8, 0xFFB5FFB5, 0xFF66FFCC, 0xFF99FFBB, 0xFF2A4A2A),
            CodeTheme("sunset", "Sunset", 0xFF1A0A05, 0xFF2A1008, 0xFFFDE2C8, 0xFFFF6B6B, 0xFFF5A623, 0xFF5A3A2A, 0xFFFFD93D, 0xFFFF9F43, 0xFFFF6348, 0xFFFFBE76, 0xFF4A2A1A),
            CodeTheme("ocean", "Ocean", 0xFF0A0E1A, 0xFF0D1830, 0xFFCCD6F6, 0xFF64FFDA, 0xFFA8FF78, 0xFF3A4A6A, 0xFF82AAFF, 0xFFC792EA, 0xFF80CBC4, 0xFF89DDFF, 0xFF2A3A5A),
            CodeTheme("forest", "Forest", 0xFF0D1810, 0xFF142018, 0xFFD0E8D0, 0xFF88C070, 0xFFE8D06C, 0xFF4A6040, 0xFFB0E080, 0xFFD0A060, 0xFF70C0A0, 0xFFA0D080, 0xFF3A5030),
            CodeTheme("candy", "Candy", 0xFF1A0820, 0xFF200A28, 0xFFF0E0FF, 0xFFFF79C6, 0xFFF1FA8C, 0xFF5A3A6A, 0xFFBD93F9, 0xFFFFB86C, 0xFF8BE9FD, 0xFFFF79C6, 0xFF4A2A5A),
            CodeTheme("ice", "Ice", 0xFF0E1620, 0xFF121E30, 0xFFE0EAF8, 0xFF7EC8E3, 0xFFA3D5FF, 0xFF3A5070, 0xFFC5E1FF, 0xFF8EB8FF, 0xFF7EC8E3, 0xFFB0D0F0, 0xFF2A4060),
        )
        val default: CodeTheme = all.first()
        fun byId(id: String?): CodeTheme = all.firstOrNull { it.id == id } ?: default
    }
}
