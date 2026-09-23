package dev.yuzi.checkin_app

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import java.util.Calendar

/**
 * 每日提醒，全部手写在原生侧。
 *
 * 为什么不用 workmanager：
 *   它为了"每 15 分钟检查一次"拉起一个后台 Flutter isolate，代价是
 *   多一个插件、多一套 Kotlin/KGP 构建坑（AGENTS.md 里记的「找不到符号
 *   WorkmanagerPlugin」就是它），而我们要的只是"到点响一次"。
 *
 * 为什么不用「精确闹钟」：
 *   setAndAllowWhileIdle 是**不需要任何新权限**的（Android 12+ 那个
 *   SCHEDULE_EXACT_ALARM 不用申请），可以穿透 Doze；对打卡提醒来说
 *   误差几分钟完全无所谓。
 *
 * 提醒文案怎么来的：
 *   App 在前台时会把自己算好的「今天还剩几项没完成」推给原生
 *   （见 setUndone），闹钟响时原生读它决定发不发、发什么。
 *   如果 App 今天没打开过（数据是旧的），就发一条通用提醒——
 *   总比不提醒好。原生**不读数据库、不依赖 Flutter 引擎**。
 */
object Reminders {
    const val CHANNEL = "dev.yuzi.checkin_app/reminders"

    private const val PREFS = "checkin_reminder"
    private const val KEY_HOUR = "hour"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_UNDONE = "undone_count"
    private const val KEY_UNDONE_DATE = "undone_date"
    private const val KEY_LAST_NOTIFIED = "last_notified_date"

    private const val CHANNEL_ID = "daily_check"
    private const val NOTIF_ID = 1001
    private const val REQ_ALARM = 4712

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---------- 设置读写 ----------

    fun setEnabled(ctx: Context, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun isEnabled(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_ENABLED, true)

    /** App 在前台算好的「今天还剩几项没完成」推给原生，闹钟响时用它拼文案 */
    fun setUndone(ctx: Context, count: Int, date: String) {
        prefs(ctx).edit()
            .putInt(KEY_UNDONE, count)
            .putString(KEY_UNDONE_DATE, date)
            .apply()
    }

    // ---------- 排闹钟 ----------

    /** 排下一次提醒；重复调用是安全的（先撤销旧的） */
    fun schedule(ctx: Context, hour: Int) {
        prefs(ctx).edit().putInt(KEY_HOUR, hour).apply()
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = alarmIntent(ctx)
        am.cancel(pi)
        if (!isEnabled(ctx)) return
        val trigger = nextTrigger(hour)
        try {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
        } catch (e: SecurityException) {
            // 极少数 ROM 仍会拦；退化成非精确闹钟，宁可晚几分钟
            am.set(AlarmManager.RTC_WAKEUP, trigger, pi)
        }
    }

    fun cancel(ctx: Context) {
        setEnabled(ctx, false)
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(alarmIntent(ctx))
    }

    private fun nextTrigger(hour: Int): Long {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= System.currentTimeMillis()) {
                add(Calendar.DAY_OF_YEAR, 1)
            }
        }
        return cal.timeInMillis
    }

    private fun alarmIntent(ctx: Context): PendingIntent {
        val i = Intent(ctx, DailyReminderReceiver::class.java)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(ctx, REQ_ALARM, i, flags)
    }

    // ---------- 通知 ----------

    fun canNotify(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) return false
        }
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.areNotificationsEnabled()
    }

    fun notify(ctx: Context, title: String, body: String) {
        if (!canNotify(ctx)) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "每日打卡提醒",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply { description = "晚上提醒你完成今天的任务" }
                nm.createNotificationChannel(ch)
            }
        }

        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val open = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java), flags
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(ctx, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(ctx)
        }
        val n = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        nm.notify(NOTIF_ID, n)
    }

    /** 闹钟响时的文案与去重判断（抽成纯函数，逻辑一眼可查） */
    fun decideBody(
        undoneCount: Int, undoneDate: String?, today: String
    ): String? {
        if (undoneDate == today) {
            // 数据是今天算的，可信
            return if (undoneCount > 0) "今天还有 $undoneCount 个任务未完成" else null
        }
        // App 今天没打开过，数据不可信 → 发通用提醒
        return "今天还有任务没完成吗？打开打卡看一眼"
    }

    fun markNotified(ctx: Context, date: String) {
        prefs(ctx).edit().putString(KEY_LAST_NOTIFIED, date).apply()
    }

    fun lastNotified(ctx: Context): String? = prefs(ctx).getString(KEY_LAST_NOTIFIED, null)
}

/** 闹钟触发：发通知 + 把明天的闹钟排上（AlarmManager 不自动重复，必须自己续） */
class DailyReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val prefs = context.getSharedPreferences("checkin_reminder", Context.MODE_PRIVATE)
        val hour = prefs.getInt("hour", 22)
        val today = todayKey()
        try {
            if (Reminders.isEnabled(context) && Reminders.lastNotified(context) != today) {
                val body = Reminders.decideBody(
                    prefs.getInt("undone_count", -1),
                    prefs.getString("undone_date", null),
                    today,
                )
                if (body != null) {
                    Reminders.notify(context, "每日打卡", body)
                    Reminders.markNotified(context, today)
                }
            }
        } catch (e: Exception) {
            // 提醒失败绝不能崩：吞掉异常，明天照常排
        }
        // 无论发没发，都把下一次排上
        try {
            Reminders.schedule(context, hour)
        } catch (e: Exception) {
        }
    }

    private fun todayKey(): String {
        val c = Calendar.getInstance()
        return String.format(
            "%04d-%02d-%02d", c.get(Calendar.YEAR),
            c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH)
        )
    }
}

/** 重启后闹钟会被系统清空，这里补排一次 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            if (Reminders.isEnabled(context)) {
                val prefs = context.getSharedPreferences("checkin_reminder", Context.MODE_PRIVATE)
                Reminders.schedule(context, prefs.getInt("hour", 22))
            }
        } catch (e: Exception) {
        }
    }
}
