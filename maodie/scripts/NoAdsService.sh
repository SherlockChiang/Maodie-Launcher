#!/system/bin/sh
# Maodie Launcher - 物理级去广告防线 (Physical AdBlocker)
# inspired by https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod

MOD_DIR="/data/adb/modules/Maodie-Launcher"
LOG_FILE="$MOD_DIR/maodie/run/adblock.log"
LOCK_FILE="$MOD_DIR/maodie/run/adblock.lock"
AD_PATHS='
/data/data/com.sankuai.meituan.takeoutnew/files/cips/common/waimai/assets/ad
/data/media/0/Android/data/com.sankuai.meituan.takeoutnew/files/cips/common/waimai/assets/promotion
/data/data/com.zhihu.android/files/ad
/data/data/tv.danmaku.bili/files/res_cache
/data/data/tv.danmaku.bili/files/update
/data/media/0/Android/data/tv.danmaku.bili/cache/default/journal
/data/data/tv.danmaku.bili/files/splash2
/data/data/com.cn21.ecloud/files/ecloud_current_screenad.obj
/data/data/tv.danmaku.bili/files/splash_top_view
/data/data/com.ai.obc.cbn.app/files/splashShow
/data/media/0/Android/data/cn.kuwo.player/files/KuwoMusic/.screenad
/data/data/cn.kuwo.player/app_adnet
/data/media/0/Android/data/cn.kuwo.player/files/KuwoMusic/.ad
/data/media/0/Android/data/com.netease.cloudmusic/cache/Ad
/data/data/com.netease.cloudmusic/cache/MusicWebApp
/data/data/cn.damai/files/ad_dir
/data/data/com.sf.activity/files/openScreenADsImg
/data/media/0/Android/data/com.yongyou/files/Pictures
/data/data/cn.missevan/cache/splash
/data/data/com.xiaomi.youpin/shared_prefs/ad_prf.xml
/data/media/0/Android/data/com.xiaomi.mico/files/data_cache/journal
/data/data/com.autonavi.minimap/files/LaunchDynamicResource
/data/data/com.autonavi.minimap/files/splash
/data/data/com.ss.android.ugc.aweme/files/im_common_resource/common_resource/scene_strategy/incentive_chat_group_panel_alpha_video_festival
/data/media/0/Android/data/com.tencent.mobileqq/files/vas_ad
/data/data/com.anjuke.android.app/cache/splash_ad
/data/data/com.bankcomm.maidanba/files/imageCachePath
/data/data/com.bankcomm.maidanba/files/tabAdsPath
/data/data/com.greenpoint.android.mc10086.activity/shared_prefs/default.xml
/data/data/com.duowan.mobile/shared_prefs/CommonPref.xml
/data/data/com.xiaomi.smarthome/files/sh_ads_file
/data/media/0/Android/data/com.mihoyo.hyperion/cache/splash
/data/data/com.cn21.ecloud/files/ecloud_current_screenad.obj
/data/media/0/Android/data/com.taobao.idlefish/files/splash_ad_assets
/data/media/0/Android/data/com.taobao.idlefish/files/ad
/data/data/com.taobao.idlefish/cache/beizi
/data/data/com.umetrip.android.msky.app/files/ad
/data/media/0/Android/data/ctrip.android.view/cache/CTADCache
/data/data/ctrip.android.view/files/CTAD
/data/media/0/Android/data/com.yipiao/files/CTADCache
/data/media/0/Android/data/com.yipiao/files/CTADSet
/data/media/0/Android/data/com.jingdong.app.mall/cache/JDVideoFileDir
/data/data/com.coocaa.familychat/app_e_qq_com_setting_7d767d052a5753acb54b111c8a40c128/sdkCloudSetting.cfg
/data/data/com.duitang.main/shared_prefs/name.xml
/data/data/com.hexin.plat.android/cache/splash_images
/data/data/com.plateno.botaoota/cache/image_manager_disk_cache
/data/data/com.tencent.map/databases/splash.db
/data/data/com.m4399.gamecenter/shared_prefs/com.m4399.gamecenter.app.xml
/data/data/com.ss.android.article.news/files/splashCache
/data/data/com.handsgo.jiakao.android/shared_prefs/mucangData.db.xml
/data/data/com.apkpure.aegon/cache/splash
/data/media/0/Android/data/com.kugou.android/files/kugou/.splash_v4
/data/data/com.coolapk.market/app_adnet/
'

mkdir -p "$MOD_DIR/maodie/run"

# 防止重复启动（使用 lock 文件，比 pgrep 更可靠）
if [ -f "$LOCK_FILE" ]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"

# 退出时清理 lock 文件
trap 'rm -f "$LOCK_FILE"; exit 0' INT TERM

echo "$(date): NoAdsService started (PID: $$)." > "$LOG_FILE"

blocked_count=0

# 广告屏蔽核心函数 (加入 2>/dev/null 容错，防止部分只读系统报错)
block_ad() {
    local target="$1"
    [ ! -e "$target" ] && return
    lsattr -d "$target" 2>/dev/null | grep -q "i.*$target" && return
    if [ -d "$target" ]; then
        rm -rf "$target" 2>/dev/null
        mkdir -p "$target" 2>/dev/null
    else
        > "$target" 2>/dev/null
    fi
    if chattr +i "$target" 2>/dev/null; then
        blocked_count=$((blocked_count + 1))
    fi
}

# 延迟 30 秒启动，把开机的 CPU 算力让给 Mihomo 和其他系统组件
sleep 30

while :; do
    blocked_count=0

    while IFS= read -r target; do
        [ -n "$target" ] && block_ad "$target"
    done <<EOF
$AD_PATHS
EOF

    [ $blocked_count -gt 0 ] && echo "$(date): Patrol done, $blocked_count path(s) blocked." >> "$LOG_FILE"

    # 巡检间隔：1小时
    sleep 3600
done
