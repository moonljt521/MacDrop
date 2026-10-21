package com.macdrop.mobile

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * 左滑露出「删除」，与 iOS 列表的滑动删除一致。
 * 未使用 RecyclerView，避免为单个交互引入 AndroidX 依赖。
 */
class SwipeRowLayout(context: Context) : FrameLayout(context) {

    private val revealWidth = (84 * resources.displayMetrics.density).toInt()
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop

    private val deleteView = TextView(context).apply {
        text = "删除"
        textSize = 14f
        setTextColor(Color.WHITE)
        gravity = Gravity.CENTER
        setBackgroundColor(Color.parseColor("#DC2626"))
        isClickable = true
        visibility = INVISIBLE
    }

    private var foreground: View? = null
    private var downX = 0f
    private var downY = 0f
    private var startOffset = 0f
    private var dragging = false

    var onDelete: (() -> Unit)? = null
    var onOpen: (() -> Unit)? = null

    init {
        addView(deleteView, LayoutParams(revealWidth, LayoutParams.MATCH_PARENT, Gravity.END))
        deleteView.setOnClickListener { onDelete?.invoke() }
    }

    fun setForeground(view: View) {
        foreground = view
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    fun close() {
        val view = foreground ?: return
        if (view.translationX == 0f) return
        snapTo(view, 0f)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        // 已展开时，点击删除区以外的位置先收起，而不是直接打开文件
        val view = foreground
        if (view != null && view.translationX < 0f && ev.actionMasked == MotionEvent.ACTION_DOWN) {
            if (ev.x < width - revealWidth) {
                close()
                return true
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        val view = foreground ?: return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = ev.rawX
                downY = ev.rawY
                startOffset = view.translationX
                dragging = false
            }

            MotionEvent.ACTION_MOVE -> {
                if (dragging) return true
                val dx = ev.rawX - downX
                val dy = ev.rawY - downY
                if (abs(dx) > touchSlop && abs(dx) > abs(dy)) {
                    dragging = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                    return true
                }
            }
        }
        return false
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        val view = foreground ?: return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                if (!dragging) return true
                val dx = ev.rawX - downX
                setOffset((startOffset + dx).coerceIn(-revealWidth.toFloat(), 0f))
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (!dragging) return true
                dragging = false
                val open = view.translationX < -revealWidth / 2f
                snapTo(view, if (open) -revealWidth.toFloat() else 0f)
                return true
            }
        }
        return true
    }

    private fun setOffset(offset: Float) {
        foreground?.translationX = offset
        deleteView.visibility = if (offset < 0f) VISIBLE else INVISIBLE
    }

    private fun snapTo(view: View, target: Float) {
        view.animate().translationX(target).setDuration(160).withEndAction {
            deleteView.visibility = if (target < 0f) VISIBLE else INVISIBLE
            if (target < 0f) onOpen?.invoke()
        }.start()
    }
}
