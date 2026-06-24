# gtm-register.sh（无凭据版）

阿里云 Cloud GTM 地址自动注册 / 公网 IP 自动更新。用于动态 IP 落地机（家宽等）开机自动把自己的当前 IP 写回 GTM 地址。

## 与旧版的区别（安全降权）

| | 旧版 | 本版 |
|---|---|---|
| 阿里云 AK | 硬编码在脚本里 | 安装时注入，只落 `/etc/gtm-register/gtm.conf`(600) |
| GitHub token | 硬编码（`repo`+`workflow` 全权）| **不需要**，脚本无密钥可公开托管 |
| 持久化副本 | 含 AK+token | 不含任何凭据 |
| 开机/cron | 跑本地副本 | 跑本地副本（不联网下载再执行）|
| 自更新 | 带 token 拉私有仓库 | 从公开 URL 拉，无 Authorization |

## 前置：建一把最小权限 RAM AK

阿里云 RAM 控制台 → 新建用户（仅 AK、不开控制台登录）→ 挂自定义策略：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:DescribeCloudGtmAddress",
        "alidns:UpdateCloudGtmAddress"
      ],
      "Resource": "*"
    }
  ]
}
```

这把 AK 即使泄露，最坏只能读/改 GTM Cloud 地址 IP，**碰不到 DNS 解析记录、ECS、OSS、RAM、账单**。
（残余风险：account 级仍可改你**所有** GTM 地址；如阿里云支持把 Resource 锁到单 AddressId 则更紧。）

## 安装（凭据走环境变量，推荐）

```bash
AK_ID=<最小权限RAM_AK> AK_SECRET=<对应Secret> \
  bash gtm-register.sh --prefix "oversea-hk" --address-id "addr-2055117389993556992"
```

或凭据走参数：

```bash
bash gtm-register.sh --ak-id <AK> --ak-secret <SECRET> \
  --prefix "oversea-hk" --address-id "addr-xxx"
```

装完后：AK 只存在于 `/etc/gtm-register/gtm.conf`(600)；systemd + 每分钟 cron 跑本地副本 `--check-ip`，IP 变了才调用阿里云更新。

## 管道安装（脚本放公开位置时）

把本脚本放到任意公开 https（公开仓库 raw / gist / 你自己的站点），然后：

```bash
GTM_SCRIPT_URL="https://<你的公开地址>/gtm-register.sh" \
AK_ID=<AK> AK_SECRET=<SECRET> \
  bash <(curl -fsSL "https://<你的公开地址>/gtm-register.sh") \
  --prefix "oversea-hk" --address-id "addr-xxx"
```

> 管道运行时脚本会用 `GTM_SCRIPT_URL` 拉一份干净副本持久化到 `/etc/gtm-register/`。
> 不设 `GTM_SCRIPT_URL` 时，请先把脚本下载为文件再运行（`cp` 自持久化，无需网络）。

## 常用命令

```bash
gtm-status                          # 查看状态
bash gtm-register.sh --check-ip     # 手动检测/更新一次
bash gtm-register.sh --self-update  # 从 GTM_SCRIPT_URL 更新本地副本（不动凭据）
bash gtm-register.sh --uninstall    # 卸载
```

## nyanpass 节点（与本脚本解耦）

`nyanpass-install.sh ... rel_nodeclient -t <token>` 是**一次性安装**，装完有自己的 systemd，重启自启，**不要**放进开机循环脚本。`-t` token 若可复用，建议在面板里改成每节点独立 token。

## 调用的阿里云接口（白名单依据）

- `alidns:DescribeCloudGtmAddress`（读现有健康探测配置，更新时原样回传避免覆盖）
- `alidns:UpdateCloudGtmAddress`（更新地址 IP）
