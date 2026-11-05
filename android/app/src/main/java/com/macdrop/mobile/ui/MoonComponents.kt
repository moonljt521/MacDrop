package com.macdrop.mobile.ui

import android.animation.ValueAnimator
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.text.TextUtils
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

private fun moonRipple(ui: MoonUi, content: Drawable?, ripple: Int): RippleDrawable =
    RippleDrawable(ColorStateList.valueOf(ripple), content, null)

fun moonRippleBackground(ui: MoonUi, color: Int): RippleDrawable =
    moonRipple(ui, null, ui.alpha(color, 0.12f))

fun moonCard(ui: MoonUi, paddingH: Int = 16, paddingV: Int = 16): LinearLayout =
    LinearLayout(ui.context).apply {
        orientation = LinearLayout.VERTICAL
        background = moonRounded(ui, ui.colors.surface, 18)
        clipToOutline = true
        setPadding(ui.dp(paddingH), ui.dp(paddingV), ui.dp(paddingH), ui.dp(paddingV))
    }

fun moonDivider(ui: MoonUi, startInsetDp: Int = 0): View = View(ui.context).apply {
    setBackgroundColor(ui.colors.divider)
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ui.dp(1)
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

fun moonIconTile(
    ui: MoonUi,
    resId: Int,
    sizeDp: Int = 40,
    iconDp: Int = 20,
    tint: Int = ui.colors.primaryStrong,
    backgroundTint: Int = ui.colors.primaryTint,
    radiusDp: Int = 13
): FrameLayout = FrameLayout(ui.context).apply {
    background = moonRounded(ui, backgroundTint, radiusDp)
    layoutParams = LinearLayout.LayoutParams(ui.dp(sizeDp), ui.dp(sizeDp))
    addView(moonIcon(ui, resId, iconDp, tint), FrameLayout.LayoutParams(
        ui.dp(iconDp), ui.dp(iconDp), Gravity.CENTER
    ))
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
        ViewGroup.LayoutParams.WRAP_CONTENT, ui.dp(28)
    )
    if (dotColor != null) {
        addView(View(ui.context).apply {
            setBackgroundColor(dotColor)
            layoutParams = LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply {
                rightMargin = ui.dp(6)
            }
            background = moonRounded(ui, dotColor, 999)
        })
    }
    addView(moonText(ui, text, 12f, textColor, ui.medium, maxLines = 1))
}

fun moonSectionHeader(ui: MoonUi, title: String, trailing: View? = null): LinearLayout =
    LinearLayout(ui.context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(ui.dp(4), ui.dp(24), ui.dp(4), ui.dp(10))
        addView(
            moonText(ui, title, 15f, ui.colors.textSecondary, ui.medium),
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        if (trailing != null) addView(trailing)
    }

fun moonIconButton(
    ui: MoonUi,
    resId: Int,
    description: String,
    tint: Int = ui.colors.textSecondary,
    onClick: () -> Unit
): FrameLayout = FrameLayout(ui.context).apply {
    background = moonRipple(
        ui, null, ui.alpha(ui.colors.textSecondary, 0.12f)
    )
    isClickable = true
    isFocusable = true
    contentDescription = description
    layoutParams = LinearLayout.LayoutParams(ui.dp(40), ui.dp(40))
    addView(moonIcon(ui, resId, 20, tint), FrameLayout.LayoutParams(
        ui.dp(20), ui.dp(20), Gravity.CENTER
    ))
    setOnClickListener { onClick() }
}

// MARK: - 按钮

class MoonButton(
    context: Context,
    private val ui: MoonUi,
    style: Style,
    text: String,
    iconRes: Int = 0
) : TextView(context) {

    enum class Style { PRIMARY, TONAL, GHOST, DANGER }

    init {
        val c = ui.colors
        this.text = text
        textSize = 15f
        typeface = ui.medium
        includeFontPadding = false
        gravity = Gravity.CENTER
        isClickable = true
        isFocusable = true
        minHeight = ui.dp(48)
        setPadding(ui.dp(16), ui.dp(10), ui.dp(16), ui.dp(10))
        compoundDrawablePadding = ui.dp(8)
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
                    moonRounded(ui, c.primary, 14),
                    ui.alpha(Color.WHITE, 0.18f)
                )
                setTextColor(c.onPrimary)
            }
            Style.TONAL -> {
                background = moonRipple(
                    ui,
                    moonRounded(ui, c.primaryTint, 14),
                    ui.alpha(c.primary, 0.14f)
                )
                setTextColor(c.primaryStrong)
            }
            Style.GHOST -> {
                background = moonRipple(ui, null, ui.alpha(c.primary, 0.10f))
                setTextColor(c.primaryStrong)
                minHeight = ui.dp(44)
            }
            Style.DANGER -> {
                background = moonRipple(
                    ui,
                    moonRounded(ui, c.dangerTint, 14),
                    ui.alpha(c.danger, 0.12f)
                )
                setTextColor(c.dangerText)
            }
        }
        stateListAnimator = null
    }

    override fun setEnabled(enabled: Boolean) {
        super.setEnabled(enabled)
        alpha = if (enabled) 1f else 0.4f
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
            contentDescription = describe()
            onCheckedChange?.invoke(value)
        }

    init {
        isClickable = true
        isFocusable = true
        minimumWidth = ui.dp(52)
        minimumHeight = ui.dp(32)
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
        setMeasuredDimension(ui.dp(52), ui.dp(32))
    }

    override fun onDraw(canvas: Canvas) {
        val h = height.toFloat()
        val w = width.toFloat()
        val inset = ui.dpf(1f)
        val radius = (h - inset * 2) / 2f
        trackPaint.color = if (position > 0.5f) {
            ui.colors.primary
        } else {
            ui.colors.surfaceMuted
        }
        canvas.drawRoundRect(
            RectF(inset, inset, w - inset, h - inset), radius, radius, trackPaint
        )
        val thumbRadius = radius - ui.dpf(2f)
        val cx = inset + radius + position * (w - inset * 2 - radius * 2)
        canvas.drawCircle(cx, h / 2f, thumbRadius, thumbPaint)
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

    private fun describe(): String = if (isChecked) "已开启" else "已关闭"
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
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(36)
        )
        labels.forEachIndexed { index, label -> addItem(label, index) }
        paintSelection()
    }

    private fun addItem(label: String, index: Int) {
        val item = moonText(ui, label, 13f, ui.colors.textSecondary, ui.medium, maxLines = 1).apply {
            gravity = Gravity.CENTER
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
            if (index == selectedIndex) {
                item.background = moonRounded(ui, ui.colors.surface, 9)
                item.setTextColor(ui.colors.primaryStrong)
                item.typeface = ui.medium
            } else {
                item.background = null
                item.setTextColor(ui.colors.textSecondary)
                item.typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            }
        }
    }
}

// MARK: - 进度条

class MoonProgressView(context: Context, private val ui: MoonUi) : View(context) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var value = 0f
    private var animator: ValueAnimator? = null

    init {
        minimumHeight = ui.dp(6)
    }

    fun setProgress(progress: Float, animated: Boolean = true) {
        val target = progress.coerceIn(0f, 1f)
        animator?.cancel()
        if (!animated) {
            value = target
            invalidate()
            return
        }
        animator = ValueAnimator.ofFloat(value, target).apply {
            duration = 200
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                value = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            MeasureSpec.getSize(widthMeasureSpec),
            ui.dp(6)
        )
    }

    override fun onDraw(canvas: Canvas) {
        val h = height.toFloat()
        val radius = h / 2f
        paint.color = ui.colors.surfaceMuted
        canvas.drawRoundRect(RectF(0f, 0f, width.toFloat(), h), radius, radius, paint)
        if (value <= 0f) return
        paint.color = ui.colors.primary
        canvas.drawRoundRect(
            RectF(0f, 0f, width.toFloat() * value, h), radius, radius, paint
        )
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
    setPadding(ui.dp(12), ui.dp(20), ui.dp(12), ui.dp(18))
    addView(moonIconTile(ui, iconRes, 44, 22, radiusDp = 14))
    addView(moonText(ui, title, 15f, ui.colors.textPrimary, ui.medium).apply {
        gravity = Gravity.CENTER
        setPadding(0, ui.dp(10), 0, 0)
    })
    addView(moonText(ui, message, 12f, ui.colors.textSecondary).apply {
        gravity = Gravity.CENTER
        setPadding(0, ui.dp(5), 0, 0)
    })
    if (actionText != null && action != null) {
        addView(MoonButton(ui.context, ui, MoonButton.Style.TONAL, actionText).apply {
            setOnClickListener { action() }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ui.dp(44)
        ).apply {
            topMargin = ui.dp(14)
        })
    }
}

// MARK: - 底部弹层

private class MaxHeightScrollView(context: Context) : ScrollView(context) {
    var maxHeight: Int = 0
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val cap = if (maxHeight > 0) {
            MeasureSpec.makeMeasureSpec(maxHeight, MeasureSpec.AT_MOST)
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
            setPadding(ui.dp(20), ui.dp(10), ui.dp(12), ui.dp(8))
        }
        titleRow.addView(
            moonText(ui, title, 17f, ui.colors.textPrimary, ui.medium, maxLines = 1),
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        titleRow.addView(moonIconButton(ui, R.drawable.ic_moon_close, "关闭") { dismiss() })
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
            setDimAmount(0.45f)
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
        if (actionCount > 0) content.addView(moonDivider(ui, 36))
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            setPadding(ui.dp(4), 0, ui.dp(4), 0)
            background = moonRipple(ui, null, ui.alpha(color, 0.10f))
            isClickable = true
            isFocusable = true
            addView(moonIcon(ui, iconRes, 22, if (danger) color else ui.colors.textSecondary))
            addView(moonText(ui, label, 15f, color).apply {
                setPadding(ui.dp(14), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            setOnClickListener { onClick() }
        }
        content.addView(row)
        actionCount++
        return this
    }
}
