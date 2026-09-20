// Command checkclaude reports whether the local environment is suitable for
// running Claude, and repairs the safe subset of problems it finds.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/zzusec/checkclaude/internal/check"
)

func main() {
	var (
		doCheck   = flag.Bool("check", false, "输出完整体检报告（默认）")
		doJSON    = flag.Bool("json", false, "输出 JSON")
		doTray    = flag.Bool("tray-status", false, "输出托盘单行 TSV")
		doBrowser = flag.Bool("browser", false, "打开浏览器采集并展示完整报告")
		doFix     = flag.Bool("fix", false, "执行安全可恢复的修复")
		doFixLoc  = flag.Bool("fix-locale", false, "额外写入当前用户的区域格式覆盖（不改显示语言）")
		doVer     = flag.Bool("version", false, "输出版本号")
	)
	flag.Parse()

	if *doVer {
		fmt.Printf("checkclaude %s\n", check.Version)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	f, r := check.Check(ctx)
	if r == nil {
		fmt.Fprintln(os.Stderr, "体检失败：评分引擎无结果")
		os.Exit(1)
	}

	switch {
	case *doTray:
		fmt.Println(check.TrayStatus(r))

	case *doJSON:
		data, err := check.JSON(f, r)
		if err != nil {
			fmt.Fprintln(os.Stderr, "JSON 序列化失败:", err)
			os.Exit(1)
		}
		fmt.Println(string(data))

	case *doBrowser:
		nf, nr, err := check.Bridge(ctx, f, r)
		if err != nil {
			fmt.Fprintln(os.Stderr, "浏览器 Bridge 启动失败:", err)
			os.Exit(1)
		}
		fmt.Print(check.Render(nf, nr))

	case *doFix || *doFixLoc:
		runFix(f, r, *doFixLoc)

	default:
		_ = doCheck
		fmt.Print(check.Render(f, r))
	}
}

func runFix(f *check.Facts, r *check.Report, fixLocale bool) {
	results, manual := check.Fix(r, f)
	if fixLocale && r.FixableLocale != "" {
		results = append(results, check.FixLocale(r.FixableLocale))
	} else if r.FixableLocale != "" {
		manual = append(manual, "• 系统区域: 区域格式与出口不符，可执行 checkclaude --fix-locale 写入用户级覆盖")
	}
	if len(results) == 0 && len(manual) == 0 {
		fmt.Println("没有需要修复的项目。")
		return
	}

	failed := false
	for _, res := range results {
		icon := "✓"
		if !res.Success {
			icon, failed = "✗", true
		}
		fmt.Printf("%s %s：%s\n", icon, res.Label, res.Message)
	}
	if len(manual) > 0 {
		fmt.Println("\n以下项目需手动处理：")
		for _, m := range manual {
			fmt.Printf("  %s\n", m)
		}
	}
	if failed {
		os.Exit(1)
	}
}
