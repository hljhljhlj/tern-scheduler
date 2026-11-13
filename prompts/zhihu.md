【定时任务 · 知乎每日维护】Tern 插件 scheduler 的 zhihu 任务投递,范围仅限下面这些,不要做任何其他事:

1) 先随机等待 0-4 分钟(`sleep $((RANDOM % 240))`;bash 单次默认 300s 超时,别更长),避开整点、模拟真人节奏。
2) 跑闸门,不要跳过:
   `bash /home/helijun/Project/maintain/zhihu/precheck.sh; echo "rc=$?"`
   - `rc=2` → 今天已执行过 / 距上次不足 2h / 不在 09:00-21:00:一句话说明原因就结束,不要打开浏览器。
   - `rc=1` → relay / Chrome 通道不通(脚本已尝试拉起 relay 与 Chrome):写一行日志就结束,不要自己登录任何账号。
   - `rc=0` → 继续。
3) 严格按 `/home/helijun/Project/maintain/zhihu/daily-task.md` 执行今天的知乎每日任务:
   工作目录 `/home/helijun/Project`;浏览器只用 omp browser relay(`app: "relay"`),禁止 surf;
   §0 幂等闸门自己 touch 名额;是否发布按 §3 判断(每 2 天最多 1 答);结束按 §5 追加日志。
4) 不要改动调度配置、插件代码或 agent 设置;不评论、不批量操作、不改资料/头像、不发想法、不点赞。
