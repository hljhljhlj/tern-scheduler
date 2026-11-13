【定时巡检 · pityplan.com】例行任务，范围仅限下面这些，不要做任何其他事：
1) 用 web_search 核对 32 款游戏（Endfield、GFL2、MHO、NTE、P5X、Umamusume、WuWa、DNA、ANANTA、Azur Promilia、Silver Palace、ZZZ、HSR、Genshin、Reverse:1999、Star Savior、Arknights、Blue Archive、PtN、PGR、Snowbreak、Limbus、FGO、Epic Seven、Azur Lane、BPSR、CookieRun: Crumble、hololive Dreams、CZN、Mecharashi、Tower of Fantasy、Silver and Blood）官方来源的卡池日程与兑换码是否有更新，优先进行中/即将开始的卡池和新兑换码。
2) 无变化 → 只回一句「巡检完成：无变化」，结束。
3) 有变化 → 先核实来源（站规：只发布有来源的事实，不写中文名、不编造数字），再更新 website/gachaverse/facts/games/*.json，然后 cd website/gachaverse && bash deploy/deploy.sh 部署并汇报。deploy 脚本自带 CJK/todo/hreflang 校验，失败就修好再部署。
4) 不要改动调度配置、插件代码或 agent 设置。
