package com.macdrop.mobile.ui

import android.animation.ValueAnimator
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.DashPathEffect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.macdrop.mobile.R

// MARK: - 基础图形

fun moonRounded(
    ui: MoonUi,
    color: Int,
    radiusDp: Int,
    strokeColor: Int? = null,
    strokeDp: Int = 0
): GradientDrawable = GradientDrawable().apply {
    shape = GradientDrawable.RECTANGLE
    setColor(color)
    cornerRadius = ui.dpf(radiusDp.toFloat())
    if (strokeColor != null && strokeDp > 0) {
        setStroke(ui.dp(strokeDp), strokeColor)
    }
}

fun moonRipple(ui: MoonUi, content: Drawable?, ripple: Int): RippleDrawable =
    RippleDrawable(ColorStateList.valueOf(ripple), content, null)

fun moonRippleBackground(ui: MoonUi, color: Int): RippleDrawable =
    moonRipple(ui, null, ui.alpha(color, 0.12f))

fun moonPanel(ui: MoonUi, paddingH: Int = 20, paddingV: Int = 20): LinearLayout =
    LinearLayout(ui.context).apply {
        orientation = LinearLayout.VERTICAL
        background = moonRounded(ui, ui.colors.surface, ui.radiusPanel)
        clipToOutline = true
        setPadding(ui.dp(paddingH), ui.dp(paddingV), ui.dp(paddingH), ui.dp(paddingV))
    }

/**
 * 分隔线：1 **物理像素**，不是 1dp。
 * 三倍屏上 1dp 的线又粗又廉价，1px 才像 iOS 那种发丝线。
 */
fun moonDivider(ui: MoonUi, startInsetDp: Int = 0): View = View(ui.context).apply {
    setBackgroundColor(ui.colors.divider)
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        1
    ).apply {
        leftMargin = ui.dp(startInsetDp)
    }
}

fun moonText(
    ui: MoonUi,
    text: String,
    sizeSp: Float,
    color: Int,
    typeface: Typeface? = null,
    maxLines: Int = Int.MAX_VALUE
): TextView = TextView(ui.context).apply {
    this.text = text
    textSize = sizeSp
    setTextColor(color)
    if (typeface != null) this.typeface = typeface
    this.maxLines = maxLines
    ellipsize = if (maxLines == 1) TextUtils.TruncateAt.END else null
    includeFontPadding = false
}

fun moonIcon(
    ui: MoonUi,
    resId: Int,
    sizeDp: Int,
    tint: Int
): ImageView = ImageView(ui.context).apply {
    setImageResource(resId)
    setColorFilter(tint)
    layoutParams = LinearLayout.LayoutParams(ui.dp(sizeDp), ui.dp(sizeDp))
    contentDescription = null
}

fun moonPill(
    ui: MoonUi,
    text: String,
    textColor: Int,
    backgroundTint: Int,
    dotColor: Int? = null
): LinearLayout = LinearLayout(ui.context).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    background = moonRounded(ui, backgroundTint, 999)
    setPadding(ui.dp(10), 0, ui.dp(10), 0)
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT, ui.dp(26)
    )
    if (dotColor != null) {
        addView(View(ui.context).apply {
            background = moonRounded(ui, dotColor, 999)
            layoutParams = LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply {
                rightMargin = ui.dp(6)
            }
        })
    }
    addView(moonText(ui, text, MoonType.LABEL, textColor, ui.medium, maxLines = 1))
}

// MARK: - 页面骨架

/**
 * 顶栏：左侧品牌名，右侧最多一个动作位。
 */
fun moonTopBar(
    ui: MoonUi,
    title: String,
    subtitle: String? = null,
    trailing: View? = null
): LinearLayout = LinearLayout(ui.context).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    val column = LinearLayout(ui.context).apply { orientation = LinearLayout.VERTICAL }
    column.addView(
        moonText(ui, title, MoonType.TOPBAR, ui.colors.textPrimary, ui.bold, maxLines = 1)
            .tracked(MoonTrack.TIGHT)
    )
    if (subtitle != null) {
        column.addView(
            moonText(ui, subtitle, MoonType.META, ui.colors.textSecondary, maxLines = 2).apply {
                setPadding(0, ui.dp(4), 0, 0)
            }
        )
    }
    addView(column, LinearLayout.LayoutParams(
        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
    ))
    if (trailing != null) {
        addView(trailing, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ))
    }
}

fun moonSectionLabel(
    ui: MoonUi,
    text: String,
    trailing: View? = null,
    typeface: Typeface = ui.bold
): LinearLayout = LinearLayout(ui.context).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    setPadding(ui.dp(2), ui.dp(28), ui.dp(2), ui.dp(12))
    addView(
        moonText(ui, text, MoonType.SECTION, ui.colors.textPrimary, typeface),
        LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
    )
    if (trailing != null) addView(trailing)
}

fun moonListRow(
    ui: MoonUi,
    iconRes: Int,
    title: String,
    subtitle: String? = null,
    trailing: View? = null,
    iconTint: Int = ui.colors.textTertiary,
    onClick: (() -> Unit)? = null
): LinearLayout = LinearLayout(ui.context).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    minimumHeight = ui.dp(72)
    setPadding(0, ui.dp(12), 0, ui.dp(12))
    if (onClick != null) {
        background = moonRippleBackground(ui, ui.colors.textSecondary)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }
    addView(moonIcon(ui, iconRes, 22, iconTint), LinearLayout.LayoutParams(
        ui.dp(22), ui.dp(22)
    ).apply {
        rightMargin = ui.dp(16)
    })
    val column = LinearLayout(ui.context).apply {
        orientation = LinearLayout.VERTICAL
    }
    column.addView(
        moonText(ui, title, MoonType.TITLE, ui.colors.textPrimary, ui.medium, maxLines = 2)
    )
    if (subtitle != null) {
        column.addView(
            moonText(ui, subtitle, MoonType.META, ui.colors.textSecondary, maxLines = 2).apply {
                setPadding(0, ui.dp(4), 0, 0)
            }
        )
    }
    addView(column, LinearLayout.LayoutParams(
        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
    ))
    if (trailing != null) {
        addView(trailing, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ))
    }
}

class MoonStatusDot(context: Context, private val ui: MoonUi) : View(context) {

    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var color = ui.colors.textTertiary

    init {
        layoutParams = LinearLayout.LayoutParams(ui.dp(22), ui.dp(22)).apply {
            rightMargin = ui.dp(4)
        }
    }

    fun setState(color: Int) {
        this.color = color
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(ui.dp(22), ui.dp(22))
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        dotPaint.color = color
        canvas.drawCircle(cx, cy, ui.dpf(3.5f), dotPaint)
    }
}

class MoonActionButton(
    context: Context,
    private val ui: MoonUi,
    text: String,
    iconRes: Int = 0,
    private val primary: Boolean = true
) : LinearLayout(context) {
    private val label = moonText(ui, text, 15f, ui.colors.onInk, ui.medium)
    private var icon: ImageView? = null

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = ui.dp(56)
        setPadding(ui.dp(12), ui.dp(14), ui.dp(12), ui.dp(14))
        isClickable = true
        isFocusable = true
        contentDescription = text
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        if (iconRes != 0) {
            icon = moonIcon(ui, iconRes, 20, ui.colors.onInk)
            addView(icon, LayoutParams(ui.dp(20), ui.dp(20)).apply {
                rightMargin = ui.dp(8)
            })
        }
        label.gravity = Gravity.CENTER
        label.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(label, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        applyLook(true)
    }

    fun applyLook(enabled: Boolean) {
        isEnabled = enabled
        val c = ui.colors
        val fill = if (!enabled) c.surfaceMuted else if (primary) c.ink else c.surface
        val tint = if (!enabled) c.textSecondary else if (primary) c.onInk else c.textPrimary
        val content = moonRounded(ui, fill, 18)
        background = if (enabled) moonRipple(ui, content, ui.alpha(tint, 0.14f)) else content
        label.setTextColor(tint)
        icon?.setColorFilter(tint)
    }

    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Button"
    }
}

/**
 * 次级文字按钮：无底、居中、安静。
 */
fun moonTextButton(ui: MoonUi, text: String, onClick: () -> Unit): TextView =
    TextView(ui.context).apply {
        this.text = text
        textSize = MoonType.BODY
        typeface = ui.medium
        includeFontPadding = false
        gravity = Gravity.CENTER
        minHeight = ui.dp(48)
        setPadding(ui.dp(16), ui.dp(8), ui.dp(16), ui.dp(8))
        background = moonRippleBackground(ui, ui.colors.primary)
        setTextColor(ui.colors.textSecondary)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

/**
 * 圆形图标按钮。中性色，不抢戏。
 */
fun moonIconButton(
    ui: MoonUi,
    resId: Int,
    description: String,
    tint: Int = ui.colors.textSecondary,
    onClick: () -> Unit
): FrameLayout = FrameLayout(ui.context).apply {
    background = moonRippleBackground(ui, ui.colors.textSecondary)
    isClickable = true
    isFocusable = true
    contentDescription = description
    minimumWidth = ui.dp(48)
    minimumHeight = ui.dp(48)
    layoutParams = LinearLayout.LayoutParams(ui.dp(48), ui.dp(48))
    addView(moonIcon(ui, resId, 20, tint), FrameLayout.LayoutParams(
        ui.dp(20), ui.dp(20), Gravity.CENTER
    ))
    setOnClickListener { onClick() }
}

// MARK: - 按钮

class MoonButton(
    context: Context,
    private val ui: MoonUi,
    private val style: Style,
    text: String,
    iconRes: Int = 0
) : TextView(context) {

    enum class Style { PRIMARY, TONAL, GHOST, DANGER }

    private val iconRes = iconRes

    init {
        this.text = text
        textSize = MoonType.BODY
        typeface = ui.medium
        includeFontPadding = false
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
        minHeight = ui.dp(48)
        setPadding(ui.dp(16), ui.dp(10), ui.dp(16), ui.dp(10))
        compoundDrawablePadding = ui.dp(8)
        applyStyle()
        stateListAnimator = null
    }

    private fun applyStyle() {
        val c = ui.colors
        if (iconRes != 0) {
            val tint = when (style) {
                Style.PRIMARY -> c.onPrimary
                Style.TONAL, Style.GHOST -> c.primaryStrong
                Style.DANGER -> c.dangerText
            }
            val drawable = resources.getDrawable(iconRes, context.theme).mutate()
            drawable.setTint(tint)
            drawable.setBounds(0, 0, ui.dp(20), ui.dp(20))
            setCompoundDrawables(drawable, null, null, null)
        }
        when (style) {
            Style.PRIMARY -> {
                background = moonRipple(
                    ui,
                    moonRounded(ui, c.primary, ui.radiusControl),
                    ui.alpha(c.onPrimary, 0.14f)
                )
                setTextColor(c.onPrimary)
            }

            Style.TONAL -> {
                background = moonRipple(
                    ui,
                    moonRounded(ui, c.surfaceMuted, ui.radiusControl),
                    ui.alpha(c.primary, 0.14f)
                )
                setTextColor(c.textPrimary)
            }

            Style.GHOST -> {
                background = moonRipple(ui, null, ui.alpha(c.primary, 0.10f))
                setTextColor(c.primaryStrong)
                minHeight = ui.dp(48)
            }

            Style.DANGER -> {
                background = moonRipple(
                    ui,
                    moonRounded(ui, c.dangerTint, ui.radiusControl),
                    ui.alpha(c.danger, 0.12f)
                )
                setTextColor(c.dangerText)
            }
        }
    }

    /**
     * 不可用时换成中性面，而不是把颜色调淡。
     */
    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        val c = ui.colors
        if (style == Style.PRIMARY && !enabled) {
            background = moonRounded(ui, c.surfaceMuted, ui.radiusControl)
            setTextColor(c.textTertiary)
            compoundDrawables[0]?.mutate()?.also {
                it.setTint(c.textTertiary)
                it.setBounds(0, 0, ui.dp(20), ui.dp(20))
                setCompoundDrawables(it, null, null, null)
            }
            alpha = 1f
        } else {
            if (enabled) applyStyle()
            alpha = if (enabled) 1f else 0.4f
        }
    }
}

// MARK: - 开关

class MoonSwitch(context: Context, private val ui: MoonUi) : View(context) {

    var onCheckedChange: ((Boolean) -> Unit)? = null

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val thumbPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var position = 0f
    private var animator: ValueAnimator? = null

    var isChecked: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            animateTo(if (value) 1f else 0f)
            sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            onCheckedChange?.invoke(value)
        }

    init {
        isClickable = true
        isFocusable = true
        minimumWidth = ui.dp(52)
        minimumHeight = ui.dp(48)
        thumbPaint.color = Color.WHITE
    }

    fun setCheckedSilently(value: Boolean) {
        if (isChecked == value) return
        isChecked = value
        position = if (value) 1f else 0f
        invalidate()
    }

    private fun animateTo(target: Float) {
        animator?.cancel()
        animator = ValueAnimator.ofFloat(position, target).apply {
            duration = 180
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                position = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(ui.dp(52), ui.dp(48))
    }

    override fun onDraw(canvas: Canvas) {
        val h = ui.dpf(32f)
        val top = (height - h) / 2f
        val w = width.toFloat()
        val inset = ui.dpf(1f)
        val radius = (h - inset * 2) / 2f
        trackPaint.color = if (position > 0.5f) {
            ui.colors.primary
        } else {
            ui.colors.surfaceMuted
        }
        canvas.drawRoundRect(
            RectF(inset, top + inset, w - inset, top + h - inset), radius, radius, trackPaint
        )
        val thumbRadius = radius - ui.dpf(2f)
        val cx = inset + radius + position * (w - inset * 2 - radius * 2)
        canvas.drawCircle(cx, height / 2f, thumbRadius, thumbPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                isPressed = true
                invalidate()
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                isPressed = false
                invalidate()
                return true
            }

            MotionEvent.ACTION_UP -> {
                isPressed = false
                performClick()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
        isChecked = !isChecked
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Switch"
        info.isCheckable = true
        info.isChecked = isChecked
    }
}

// MARK: - 分段控件

class MoonSegmented(
    context: Context,
    private val ui: MoonUi,
    labels: List<String>,
    initial: Int = 0,
    private val onSelect: (Int) -> Unit
) : LinearLayout(context) {

    private val items = mutableListOf<TextView>()
    private var selectedIndex = initial

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = moonRounded(ui, ui.colors.surfaceMuted, 12)
        setPadding(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3))
        minimumHeight = ui.dp(54)
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        )
        labels.forEachIndexed { index, label -> addItem(label, index) }
        paintSelection()
    }

    private fun addItem(label: String, index: Int) {
        val item = moonText(ui, label, MoonType.META, ui.colors.textSecondary, ui.medium).apply {
            gravity = Gravity.CENTER
            minHeight = ui.dp(48)
            setPadding(ui.dp(8), ui.dp(10), ui.dp(8), ui.dp(10))
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (selectedIndex == index) return@setOnClickListener
                selectedIndex = index
                paintSelection()
                onSelect(index)
            }
        }
        items.add(item)
        addView(item, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
    }

    fun setLabel(index: Int, label: String) {
        items.getOrNull(index)?.text = label
    }

    fun select(index: Int, notify: Boolean = true) {
        if (index !in items.indices || index == selectedIndex) return
        selectedIndex = index
        paintSelection()
        if (notify) onSelect(index)
    }

    private fun paintSelection() {
        items.forEachIndexed { index, item ->
            item.isSelected = index == selectedIndex
            if (index == selectedIndex) {
                item.background = moonRipple(
                    ui, moonRounded(ui, ui.colors.surface, 10), ui.alpha(ui.colors.primary, 0.12f)
                )
                item.setTextColor(ui.colors.textPrimary)
                item.typeface = ui.medium
            } else {
                item.background = moonRippleBackground(ui, ui.colors.primary)
                item.setTextColor(ui.colors.textSecondary)
                item.typeface = ui.regular
            }
        }
    }
}

// MARK: - 近场设备台（圆弧只是构图，不表示距离）

class MoonCrescentView(context: Context, private val ui: MoonUi) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ui.colors.textPrimary }
    private val shape = Path()

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        val radius = minOf(w, h) * 0.46f
        shape.reset()
        shape.addCircle(w / 2f, h / 2f, radius, Path.Direction.CW)
        val cutout = Path().apply {
            addCircle(w * 0.73f, h * 0.29f, radius, Path.Direction.CW)
        }
        shape.op(cutout, Path.Op.DIFFERENCE)
    }

    override fun onDraw(canvas: Canvas) { canvas.drawPath(shape, paint) }
}

data class MoonNearbyDevice(val name: String, val connection: String, val onClick: () -> Unit)

private class MoonPeerButton(private val ui: MoonUi, device: MoonNearbyDevice) : LinearLayout(ui.context) {
    private var listMode: Boolean? = null
    private var density = -1
    private val icon = moonIcon(ui, R.drawable.ic_moon_device, 34, ui.colors.textPrimary)
    private val glyph = FrameLayout(context).apply {
        background = moonRounded(ui, ui.colors.surface, 24)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(icon, FrameLayout.LayoutParams(ui.dp(34), ui.dp(34), Gravity.CENTER))
    }
    private val name = moonText(ui, device.name, 13f, ui.colors.textPrimary, ui.medium, maxLines = 2).apply {
        ellipsize = TextUtils.TruncateAt.END
    }
    private val connection = moonText(ui, device.connection, 12f, ui.colors.textSecondary)
    private val labels = LinearLayout(context).apply {
        orientation = VERTICAL
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        addView(name, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(connection, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = ui.dp(4)
        })
    }

    init {
        minimumHeight = ui.dp(72)
        background = moonRippleBackground(ui, ui.colors.primary)
        isClickable = true
        isFocusable = true
        contentDescription = MoonStrings.f("发送到 %s，%s", device.name, device.connection)
        addView(glyph)
        addView(labels)
        setOnClickListener { device.onClick() }
        setListMode(false)
    }

    fun needsListMode(width: Int): Boolean =
        name.paint.measureText(name.text.toString()) > width * 2f ||
            name.text.contains('\n') || connection.paint.measureText(connection.text.toString()) > width

    fun setListMode(list: Boolean) {
        if (listMode == list) return
        listMode = list
        orientation = if (list) HORIZONTAL else VERTICAL
        gravity = if (list) Gravity.CENTER_VERTICAL else Gravity.CENTER_HORIZONTAL
        setPadding(0, ui.dp(6), 0, ui.dp(6))
        glyph.layoutParams = LayoutParams(ui.dp(68), ui.dp(68))
        labels.layoutParams = if (list) LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply {
            leftMargin = ui.dp(16)
        } else LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = ui.dp(8)
        }
        name.maxLines = if (list) Int.MAX_VALUE else 2
        name.gravity = if (list) Gravity.START else Gravity.CENTER
        connection.gravity = name.gravity
    }

    fun setDensity(level: Int) {
        if (density == level) return
        density = level
        val glyphSize = ui.dp(when (level) { 0 -> 68; 1 -> 56; else -> 50 })
        glyph.layoutParams = LayoutParams(glyphSize, glyphSize)
        val iconSize = ui.dp(when (level) { 0 -> 34; 1 -> 27; else -> 24 })
        icon.layoutParams = FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER)
        name.setTextSize(TypedValue.COMPLEX_UNIT_SP, when (level) { 0 -> 13f; 1 -> 12.5f; else -> 11.5f })
        connection.setTextSize(TypedValue.COMPLEX_UNIT_SP, when (level) { 0 -> 12f; 1 -> 11.5f; else -> 11f })
        if (listMode != true) {
            name.maxLines = if (level >= 2) 1 else 2
            labels.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                topMargin = ui.dp(if (level == 0) 8 else 6)
            }
            labels.requestLayout()
        }
        requestLayout()
    }

    override fun onInitializeAccessibilityNodeInfo(info: android.view.accessibility.AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Button"
    }
}

private class MoonOrbitLayout(private val ui: MoonUi) : ViewGroup(ui.context) {
    private val peers = mutableListOf<MoonPeerButton>()
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ui.colors.divider
        style = Paint.Style.STROKE
        strokeWidth = ui.dpf(0.75f)
    }
    private val dotted = DashPathEffect(floatArrayOf(ui.dpf(2f), ui.dpf(7f)), 0f)
    private val arc = RectF()
    private var listMode = false
    private var localTop = 0
    private var rowLowerTop = 0
    private val local = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        contentDescription = MoonStrings.t("此设备")
        addView(FrameLayout(context).apply {
            background = moonRounded(ui, ui.colors.surfaceMuted, 999)
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            addView(moonIcon(ui, R.drawable.ic_moon_device, 30, ui.colors.primary),
                FrameLayout.LayoutParams(ui.dp(30), ui.dp(30), Gravity.CENTER))
        }, LinearLayout.LayoutParams(ui.dp(78), ui.dp(78)))
        addView(moonText(ui, MoonStrings.t("此设备"), 12f, ui.colors.textSecondary).apply {
            gravity = Gravity.CENTER
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            topMargin = ui.dp(12)
        })
    }
    private val empty = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        addView(moonText(ui, MoonStrings.t("等待设备出现"), 17f, ui.colors.textPrimary, ui.medium).apply {
            gravity = Gravity.CENTER
        })
        addView(moonText(ui, MoonStrings.t("在另一台设备上打开 MoonDrop\n同一 Wi-Fi 下自动发现"), 13f, ui.colors.textSecondary).apply {
            gravity = Gravity.CENTER
            setLineSpacing(0f, 1.35f)
            setPadding(0, ui.dp(8), 0, 0)
        })
    }

    init {
        setWillNotDraw(false)
        addView(empty)
        addView(local)
    }

    fun setDevices(devices: List<MoonNearbyDevice>) {
        peers.forEach { removeView(it) }
        peers.clear()
        devices.forEach { device ->
            val button = MoonPeerButton(ui, device)
            peers.add(button)
            addView(button)
        }
        empty.visibility = if (peers.isEmpty()) VISIBLE else GONE
        requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val stageWidth = (width * if (peers.size >= 4) 0.31f else 0.30f).toInt()
        val fontScale = resources.configuration.fontScale
        listMode = fontScale >= 1.4f || width < ui.dp(320) ||
            peers.size > 6 || (peers.size >= 6 && fontScale >= 1.2f) ||
            peers.any { it.needsListMode(stageWidth) }
        val unspecified = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        local.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), unspecified)
        if (peers.isEmpty()) {
            empty.measure(MeasureSpec.makeMeasureSpec((width - ui.dp(24)).coerceAtLeast(0), MeasureSpec.EXACTLY), unspecified)
            localTop = maxOf(ui.dp(212), ui.dp(48) + empty.measuredHeight + ui.dp(24))
        } else if (listMode) {
            var top = ui.dp(8)
            peers.forEach { peer ->
                peer.setListMode(true)
                peer.setDensity(0)
                peer.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY), unspecified)
                top += peer.measuredHeight + ui.dp(8)
            }
            localTop = top + ui.dp(20)
        } else {
            val level = if (peers.size >= 6) 2 else if (peers.size >= 4) 1 else 0
            peers.forEach { peer ->
                peer.setListMode(false)
                peer.setDensity(level)
                peer.measure(MeasureSpec.makeMeasureSpec(stageWidth, MeasureSpec.EXACTLY), unspecified)
            }
            if (peers.size >= 4) {
                val gap = if (peers.size >= 6) ui.dp(4) else ui.dp(12)
                rowLowerTop = ui.dp(8) + peers.maxOf { it.measuredHeight } + gap
            }
            localTop = ui.dp(212)
        }
        setMeasuredDimension(width, maxOf(ui.dp(320), localTop + local.measuredHeight + ui.dp(8)))
    }

    private fun stageSlots(count: Int): List<Pair<Float, Int>> = when (count) {
        1 -> listOf(0.5f to 0)
        2 -> listOf(0.28f to 0, 0.72f to 0)
        3 -> listOf(0.5f to 0, 0.16f to 1, 0.84f to 1)
        4 -> listOf(0.27f to 0, 0.73f to 0, 0.165f to 1, 0.835f to 1)
        5 -> listOf(0.17f to 0, 0.5f to 0, 0.83f to 0, 0.24f to 1, 0.76f to 1)
        else -> listOf(
            0.17f to 0, 0.5f to 0, 0.83f to 0,
            0.17f to 1, 0.5f to 1, 0.83f to 1
        )
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val width = right - left
        local.layout(0, localTop, width, localTop + local.measuredHeight)
        if (peers.isEmpty()) {
            val x = (width - empty.measuredWidth) / 2
            empty.layout(x, ui.dp(48), x + empty.measuredWidth, ui.dp(48) + empty.measuredHeight)
        } else if (listMode) {
            var y = ui.dp(8)
            peers.forEach { peer ->
                peer.layout(0, y, width, y + peer.measuredHeight)
                y += peer.measuredHeight + ui.dp(8)
            }
        } else {
            val upperTop = ui.dp(if (peers.size >= 4) 8 else 12)
            val lowerTop = if (peers.size >= 4) rowLowerTop else ui.dp(108)
            val slots = stageSlots(peers.size)
            peers.forEachIndexed { index, peer ->
                val (fraction, row) = slots[index]
                val x = (width * fraction).toInt() - peer.measuredWidth / 2
                val y = if (row == 0) upperTop else lowerTop
                peer.layout(x, y, x + peer.measuredWidth, y + peer.measuredHeight)
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        if (listMode && peers.isNotEmpty()) return
        val cx = width / 2f
        val cy = localTop + ui.dpf(39f)
        for ((index, fraction) in listOf(0.49f, 0.40f, 0.285f).withIndex()) {
            val radius = width * fraction
            line.pathEffect = if (index == 2) dotted else null
            arc.set(cx - radius, cy - radius, cx + radius, cy + radius)
            canvas.drawArc(arc, 180f, 180f, false, line)
        }
        line.pathEffect = null
    }
}

class MoonNearfieldView(context: Context, private val ui: MoonUi) : LinearLayout(context) {
    private val orbit = MoonOrbitLayout(ui)

    init {
        orientation = VERTICAL
        addView(orbit, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    fun setDevices(devices: List<MoonNearbyDevice>) {
        orbit.setDevices(devices)
    }
}

// MARK: - 实际进度环（不使用计时器或模拟进度）

class MoonProgressView(context: Context, private val ui: MoonUi) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val bounds = RectF()
    private var value = 0f
    private var color = ui.colors.primary

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun setProgress(progress: Float, color: Int = ui.colors.primary) {
        value = if (progress.isFinite()) progress.coerceIn(0f, 1f) else 0f
        this.color = color
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val radius = minOf(width, height) / 2f - ui.dpf(5f)
        bounds.set(width / 2f - radius, height / 2f - radius, width / 2f + radius, height / 2f + radius)
        paint.strokeWidth = ui.dpf(2f)
        paint.color = ui.colors.divider
        canvas.drawOval(bounds, paint)
        if (value > 0f) {
            paint.strokeWidth = ui.dpf(3f)
            paint.color = color
            canvas.drawArc(bounds, -90f, value * 360f, false, paint)
        }
    }
}

// MARK: - 空状态

fun moonEmptyState(
    ui: MoonUi,
    iconRes: Int,
    title: String,
    message: String,
    actionText: String? = null,
    action: (() -> Unit)? = null
): LinearLayout = LinearLayout(ui.context).apply {
    orientation = LinearLayout.VERTICAL
    gravity = Gravity.CENTER_HORIZONTAL
    setPadding(ui.dp(12), ui.dp(28), ui.dp(12), ui.dp(24))
    addView(moonIcon(ui, iconRes, 22, ui.colors.textTertiary))
    addView(moonText(ui, title, MoonType.TITLE, ui.colors.textPrimary, ui.regular).apply {
        gravity = Gravity.CENTER
        setPadding(0, ui.dp(14), 0, 0)
    })
    addView(moonText(ui, message, MoonType.META, ui.colors.textTertiary).apply {
        gravity = Gravity.CENTER
        setPadding(0, ui.dp(6), 0, 0)
        setLineSpacing(0f, 1.35f)
    })
    if (actionText != null && action != null) {
        addView(MoonButton(ui.context, ui, MoonButton.Style.TONAL, actionText).apply {
            setOnClickListener { action() }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = ui.dp(18)
        })
    }
}

// MARK: - 底部弹层

private class MaxHeightScrollView(context: Context) : ScrollView(context) {
    var maxHeight: Int = 0
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val cap = if (maxHeight > 0) {
            val available = if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED) {
                maxHeight
            } else {
                minOf(maxHeight, MeasureSpec.getSize(heightMeasureSpec))
            }
            MeasureSpec.makeMeasureSpec(available, MeasureSpec.AT_MOST)
        } else {
            heightMeasureSpec
        }
        super.onMeasure(widthMeasureSpec, cap)
    }
}

class MoonSheet(
    context: Context,
    private val ui: MoonUi,
    title: String
) : Dialog(context, R.style.MoonSheetDialog) {

    private val content = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(ui.dp(20), 0, ui.dp(20), ui.dp(16))
    }

    private val screenHeight = context.resources.displayMetrics.heightPixels
    private var actionCount = 0

    init {
        requestWindowFeature(Window.FEATURE_NO_TITLE)

        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(ui.colors.surface)
                cornerRadii = floatArrayOf(
                    ui.dpf(24f), ui.dpf(24f),
                    ui.dpf(24f), ui.dpf(24f),
                    0f, 0f, 0f, 0f
                )
            }
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(0, 0, 0, insets.systemWindowInsetBottom)
                insets
            }
        }

        root.addView(View(context).apply {
            background = moonRounded(ui, ui.colors.divider, 999)
            layoutParams = LinearLayout.LayoutParams(ui.dp(36), ui.dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                topMargin = ui.dp(8)
            }
        })

        val titleRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(20), ui.dp(12), ui.dp(12), ui.dp(10))
        }
        titleRow.addView(
            moonText(ui, title, 17f, ui.colors.textPrimary, ui.medium, maxLines = 2).apply {
                ellipsize = TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        titleRow.addView(moonIconButton(ui, R.drawable.ic_moon_close, MoonStrings.t("关闭")) { dismiss() })
        root.addView(titleRow)

        val scroller = MaxHeightScrollView(context).apply {
            isFillViewport = false
            maxHeight = (screenHeight * 0.74f).toInt()
            addView(content, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ))
        }
        root.addView(scroller, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

        setContentView(root)
        window?.apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            setGravity(Gravity.BOTTOM)
            addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
            setDimAmount(0.4f)
        }
        setCanceledOnTouchOutside(true)
    }

    fun add(view: View): MoonSheet {
        content.addView(view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        return this
    }

    fun addAction(
        iconRes: Int,
        label: String,
        danger: Boolean = false,
        onClick: () -> Unit
    ): MoonSheet {
        val color = if (danger) ui.colors.dangerText else ui.colors.textPrimary
        if (actionCount > 0) content.addView(moonDivider(ui, 44))
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            setPadding(ui.dp(4), 0, ui.dp(4), 0)
            background = moonRipple(ui, null, ui.alpha(color, 0.10f))
            isClickable = true
            isFocusable = true
            addView(moonIcon(ui, iconRes, 20, if (danger) color else ui.colors.textTertiary))
            addView(moonText(ui, label, MoonType.TITLE, color, ui.regular).apply {
                setPadding(ui.dp(16), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            setOnClickListener { onClick() }
        }
        content.addView(row)
        actionCount++
        return this
    }
}
