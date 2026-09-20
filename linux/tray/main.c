/*
 * checkclaude-tray — GTK3 + Ayatana AppIndicator front-end for the
 * checkclaude CLI. It owns no detection logic: every 60 seconds it runs
 * `checkclaude --tray-status` and renders the five TSV columns it prints.
 *
 * Build: see linux/build.sh
 */
#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>
#include <string.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#define CLI "checkclaude"
#define REFRESH_SECONDS 60

static AppIndicator *indicator;
static GtkWidget *item_status, *item_fix;
static gboolean busy = FALSE;

/* ── helpers ── */

static void show_dialog(GtkMessageType type, const char *title, const char *body) {
    GtkWidget *d = gtk_message_dialog_new(NULL, 0, type, GTK_BUTTONS_CLOSE, "%s", title);
    if (body && *body)
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(d), "%s", body);
    gtk_window_set_title(GTK_WINDOW(d), "CheckClaude");
    g_signal_connect(d, "response", G_CALLBACK(gtk_widget_destroy), NULL);
    gtk_widget_show_all(d);
}

/* Icon names come from the system theme so the tray follows the user's icons. */
static const char *icon_for_risk(const char *risk, int score) {
    if (risk && (strstr(risk, "极高") || strstr(risk, "高风险"))) return "security-low";
    if (risk && strstr(risk, "中风险")) return "security-medium";
    if (risk && strstr(risk, "低风险")) return "security-medium";
    if (risk && strstr(risk, "安全")) return "security-high";
    return score >= 85 ? "security-high" : "security-medium";
}

static void set_unknown(const char *why) {
    app_indicator_set_icon_full(indicator, "dialog-question", "CheckClaude");
    app_indicator_set_label(indicator, "--", "100");
    gtk_menu_item_set_label(GTK_MENU_ITEM(item_status), why);
}

/* ── status refresh ── */

static void on_status_done(GObject *src, GAsyncResult *res, gpointer user_data) {
    gboolean interactive = GPOINTER_TO_INT(user_data);
    GSubprocess *proc = G_SUBPROCESS(src);
    char *out = NULL, *err = NULL;
    GError *error = NULL;

    busy = FALSE;
    if (!g_subprocess_communicate_utf8_finish(proc, res, &out, &err, &error)) {
        set_unknown("无法运行 checkclaude");
        if (interactive)
            show_dialog(GTK_MESSAGE_ERROR, "无法运行 checkclaude",
                        error ? error->message : "请确认 /usr/bin/checkclaude 已安装");
        g_clear_error(&error);
        g_object_unref(proc);
        return;
    }

    if (!g_subprocess_get_successful(proc)) {
        set_unknown("体检失败");
        if (interactive)
            show_dialog(GTK_MESSAGE_ERROR, "体检失败",
                        (err && *err) ? err : "checkclaude 返回了非零退出码");
        goto done;
    }

    /* score \t riskLevel \t country \t verdict \t fixList */
    g_strstrip(out ? out : (out = g_strdup("")));
    char **col = g_strsplit(out, "\t", 5);
    if (g_strv_length(col) < 4) {
        set_unknown("输出格式异常");
        g_strfreev(col);
        goto done;
    }

    int score = atoi(col[0]);
    char *label = g_strdup_printf("%d", score);
    char *tip = g_strdup_printf("CheckClaude %d 分 · %s · %s", score, col[1], col[2]);
    char *menu = g_strdup_printf("%d 分 · %s · %s", score, col[1], col[2]);

    app_indicator_set_icon_full(indicator, icon_for_risk(col[1], score), tip);
    app_indicator_set_label(indicator, label, "100");
    app_indicator_set_title(indicator, tip);
    gtk_menu_item_set_label(GTK_MENU_ITEM(item_status), menu);

    gboolean has_fix = g_strv_length(col) >= 5 && col[4] && *col[4];
    gtk_widget_set_sensitive(item_fix, has_fix);
    if (has_fix) {
        char *fl = g_strdup_printf("一键修复（%s）", col[4]);
        gtk_menu_item_set_label(GTK_MENU_ITEM(item_fix), fl);
        g_free(fl);
    } else {
        gtk_menu_item_set_label(GTK_MENU_ITEM(item_fix), "一键修复");
    }

    if (interactive)
        show_dialog(GTK_MESSAGE_INFO, menu, col[3]);

    g_free(label); g_free(tip); g_free(menu);
    g_strfreev(col);

done:
    g_free(out); g_free(err);
    g_object_unref(proc);
}

static void refresh(gboolean interactive) {
    if (busy) return;
    GError *error = NULL;
    GSubprocess *proc = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE,
        &error, CLI, "--tray-status", NULL);
    if (!proc) {
        set_unknown("无法运行 checkclaude");
        if (interactive)
            show_dialog(GTK_MESSAGE_ERROR, "无法运行 checkclaude",
                        error ? error->message : NULL);
        g_clear_error(&error);
        return;
    }
    busy = TRUE;
    gtk_menu_item_set_label(GTK_MENU_ITEM(item_status), "正在体检…");
    g_subprocess_communicate_utf8_async(proc, NULL, NULL, on_status_done,
                                        GINT_TO_POINTER(interactive));
}

static gboolean on_timer(gpointer _u) { refresh(FALSE); return G_SOURCE_CONTINUE; }

/* ── menu actions ── */

static void on_recheck(GtkMenuItem *_i, gpointer _u) { refresh(TRUE); }

static void on_report(GtkMenuItem *_i, gpointer _u) {
    GError *error = NULL;
    /* --browser opens the default browser itself and then exits. */
    if (!g_spawn_command_line_async(CLI " --browser", &error)) {
        show_dialog(GTK_MESSAGE_ERROR, "无法打开完整报告",
                    error ? error->message : NULL);
        g_clear_error(&error);
    }
}

static void on_fix_done(GObject *src, GAsyncResult *res, gpointer _u) {
    GSubprocess *proc = G_SUBPROCESS(src);
    char *out = NULL, *err = NULL;
    GError *error = NULL;

    busy = FALSE;
    gtk_widget_set_sensitive(item_fix, TRUE);
    if (!g_subprocess_communicate_utf8_finish(proc, res, &out, &err, &error)) {
        show_dialog(GTK_MESSAGE_ERROR, "修复失败", error ? error->message : NULL);
        g_clear_error(&error);
        g_object_unref(proc);
        return;
    }
    gboolean ok = g_subprocess_get_successful(proc);
    show_dialog(ok ? GTK_MESSAGE_INFO : GTK_MESSAGE_WARNING,
                ok ? "修复完成" : "修复未全部成功",
                (out && *out) ? out : err);
    g_free(out); g_free(err);
    g_object_unref(proc);
    refresh(FALSE);
}

static void on_fix(GtkMenuItem *_i, gpointer _u) {
    if (busy) return;
    GError *error = NULL;
    GSubprocess *proc = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE,
        &error, CLI, "--fix", NULL);
    if (!proc) {
        show_dialog(GTK_MESSAGE_ERROR, "无法运行修复", error ? error->message : NULL);
        g_clear_error(&error);
        return;
    }
    busy = TRUE;
    gtk_widget_set_sensitive(item_fix, FALSE);
    g_subprocess_communicate_utf8_async(proc, NULL, NULL, on_fix_done, NULL);
}

static void on_quit(GtkMenuItem *_i, gpointer _u) { gtk_main_quit(); }

/* ── main ── */

/* Single instance: the desktop entry and the autostart entry both launch this
 * binary, so a second launch means "show me the report" rather than a second
 * tray icon. */
static gboolean claim_single_instance(void) {
    char *path = g_build_filename(g_get_user_runtime_dir(), "checkclaude-tray.lock", NULL);
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    g_free(path);
    if (fd < 0) return TRUE; /* no runtime dir: don't block startup */
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        close(fd);
        return FALSE;
    }
    return TRUE; /* fd stays open for the process lifetime */
}

int main(int argc, char **argv) {
    /* gtk_init 在没有 DISPLAY 时直接 abort，服务器上装了 deb 又误跑托盘的人
     * 会看到一串 GTK 崩溃信息。改用 _check 版本，给一句人话再退。 */
    if (!gtk_init_check(&argc, &argv)) {
        g_printerr("没有可用的图形界面（DISPLAY/WAYLAND_DISPLAY 未设置）。\n"
                   "服务器上请直接用命令行：checkclaude --check\n");
        return 1;
    }

    if (!claim_single_instance()) {
        g_spawn_command_line_async(CLI " --browser", NULL);
        return 0;
    }

    GtkWidget *menu = gtk_menu_new();

    item_status = gtk_menu_item_new_with_label("正在体检…");
    gtk_widget_set_sensitive(item_status, FALSE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_status);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());

    GtkWidget *item_recheck = gtk_menu_item_new_with_label("重新体检");
    g_signal_connect(item_recheck, "activate", G_CALLBACK(on_recheck), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_recheck);

    GtkWidget *item_report = gtk_menu_item_new_with_label("打开完整报告");
    g_signal_connect(item_report, "activate", G_CALLBACK(on_report), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_report);

    item_fix = gtk_menu_item_new_with_label("一键修复");
    gtk_widget_set_sensitive(item_fix, FALSE);
    g_signal_connect(item_fix, "activate", G_CALLBACK(on_fix), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_fix);

    gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
    GtkWidget *item_quit = gtk_menu_item_new_with_label("退出");
    g_signal_connect(item_quit, "activate", G_CALLBACK(on_quit), NULL);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_quit);

    gtk_widget_show_all(menu);

    indicator = app_indicator_new("checkclaude", "dialog-question",
                                  APP_INDICATOR_CATEGORY_SYSTEM_SERVICES);
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);
    app_indicator_set_menu(indicator, GTK_MENU(menu));
    app_indicator_set_title(indicator, "CheckClaude");

    refresh(FALSE);
    g_timeout_add_seconds(REFRESH_SECONDS, on_timer, NULL);

    gtk_main();
    return 0;
}
