#!/bin/bash

########################################
# eBPF config
########################################
function cat_ebpf_config() {
  echo "CONFIG_BPF=y" >> "$1"
  echo "CONFIG_BPF_SYSCALL=y" >> "$1"
  echo "CONFIG_NET_CLS_BPF=y" >> "$1"
  echo "CONFIG_NET_ACT_BPF=y" >> "$1"
}

########################################
# kernel config merge
########################################
function cat_kernel_config() {
  local file="$1"
  [ -f "$file" ] && cat "$file" >> .config
}

########################################
# remove wifi (你没定义过但在用)
########################################
function remove_wifi() {
  echo "# WIFI disabled for $1" >> .config
}

# skb 回收
function enable_skb_recycler() {
  if [ -f "$1" ]; then
    cat >> "$1" <<EOF

CONFIG_KERNEL_SKB_RECYCLER=y
CONFIG_KERNEL_SKB_RECYCLER_MULTI_CPU=y
EOF
  fi
}

########################################
# 修改内核大小
########################################

function set_kernel_size() {

  for file in target/linux/qualcommax/image/*.mk; do
    sed -i 's/KERNEL_SIZE := [0-9]*k/KERNEL_SIZE := 12288k/g' "$file"
  done

}

########################################
# 生成最终 .config
########################################

function generate_config() {

  config_file=".config"

  cat "$GITHUB_WORKSPACE/Config/${WRT_CONFIG}.txt" \
      "$GITHUB_WORKSPACE/Config/GENERAL.txt" > "$config_file"

  local target=$(echo "$WRT_ARCH" | cut -d'_' -f2)

  # 删除 WIFI
  if [[ "$WRT_CONFIG" == *"NOWIFI"* ]]; then
    remove_wifi "$target"
  fi

  # eBPF
  cat_ebpf_config "$config_file"

  # skb recycler
  enable_skb_recycler "$config_file"

  # 内核大小
  set_kernel_size

  # 写入 kernel config
  cat_kernel_config "target/linux/qualcommax/${target}/config-default"

}

########################################
# 移除不用的 5G CPE/QModem 包，避免缺失依赖影响 olddefconfig
########################################
function remove_unused_5g_packages() {
  local qmodem_patterns=(
    "./package/QModem"
    "./package/feeds/*/qmodem"
  )

  for pattern in "${qmodem_patterns[@]}"; do
    for path in $pattern; do
      [ -e "$path" ] || continue
      echo "remove unused 5G package: $path"
      rm -rf "$path"
    done
  done
}

########################################
# 修复第三方包缺失依赖导致 olddefconfig 失败
########################################
function fix_missing_dependencies() {
  # feeds install 后，olddefconfig 扫描的是 package/feeds 下的入口；
  # 同时处理 feeds 源路径和 package/feeds 链接路径，避免漏修。
  local onionshare_files=(
    "./feeds/packages/net/onionshare-cli/Makefile"
    "./package/feeds/packages/onionshare-cli/Makefile"
  )

  for mk in "${onionshare_files[@]}"; do
    [ -f "$mk" ] || continue

    # 当前源码没有 python3-py-socks/python3-text-unidecode 时，替换仍会失败；
    # 移除这些非核心硬依赖，让配置阶段先通过。
    sed -i \
      -e 's/+python3-pysocks//g' \
      -e 's/+python3-py-socks//g' \
      -e 's/+python3-unidecode//g' \
      -e 's/+python3-text-unidecode//g' \
      "$mk"
  done
}

########################################
# 执行生成 config
########################################

generate_config
remove_unused_5g_packages
fix_missing_dependencies

########################################
# Luci / 系统修改
########################################

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#开启sqm-nss插件
	echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
	echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	#其他调整
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi
