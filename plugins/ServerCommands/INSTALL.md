# ServerCommands پلاگین — نصب روی سرور (v5.6.2)

این پلاگین مرکزیِ مدیریت سرور CS2 است: دستورات ادمین + منوها، تگ ادمین/اونر، گَگ/میوت، بن واقعی هر سرور، جریان مسابقه (شروع/پایان/نايف/پاز)، مودهای اسکریپتی (casual/comp/dm/mix/aim/prac/retakes)، و کل سیستم VIP (VIP 1 تا VIP 5؛ VIP 5 = ۱۳۰ افکت کازمتیک). همین DLL روی سرورهای CS2Nexus در حال اجراست.

## محتویات بستهٔ deploy
```
ServerCommands/
├── ServerCommands.dll        ← پلاگین کامپایل‌شده (Cecil-patched v5.6.2، 263680 بایت)
├── plugin.json               ← معرفی پلاگین + فهرست کامل دستورات (برای CounterStrikeSharp)
├── version.txt               ← 5.6.2
└── configs/
    └── plugins/
        └── ServerCommands/
            └── ServerCommands.json   ← نمونهٔ تنظیمات (تمام پیش‌فرض‌ها)
```

## نصب روی یک سرور بازی
1. پوشه را در مسیر پلاگین‌های CounterStrikeSharp کپی کنید:
   ```
   addons/counterstrikesharp/plugins/ServerCommands/ServerCommands.dll
   addons/counterstrikesharp/plugins/ServerCommands/plugin.json
   ```
   (اگر نسخهٔ قدیمی موجود است، `ServerCommands.dll` قبلی را با این یکی جایگزین کنید. نیازی به تغییر `plugin.json` یا `version.txt` نیست.)
2. تنظیمات را در مسیر کانفیگ بگذارید (اگر هنوز نیست):
   ```
   addons/counterstrikesharp/configs/plugins/ServerCommands/ServerCommands.json
   ```
   فایل `configs/.../ServerCommands.json` همین بسته یک نمونهٔ کامل با پیش‌فرض‌هاست. CounterStrikeSharp هر فیلد ناقص را با پیش‌فرض پر می‌کند.
3. سرور را یک‌بار ری‌استارت کنید تا پلاگین لود شود. پس از آن، تغییرات `ServerCommands.json` توسط پلاگین **هات-ریلود** می‌شود (نیازی به ری‌استارت ندارد).

## اتصال به سایت CS2Nexus (قرارداد site↔plugin)
پلاگین از طریق **پل فایلِ لانچر** به پنل وصل است (هیچ HTTPای از داخل پلاگین زده نمی‌شود؛ NexusLink پل HTTP است):

| جهت | چه چیزی | مسیر |
| --- | --- | --- |
| سایت ← پلاگین | ۴ تاگل پیکربندی (`ApplyNameTags`, `AdminsCommandEnabled`, `OwnerTag`, `DefaultAdminTag`) | پنل → لانچر می‌نویسد `ServerCommands.json` + می‌فرستد `css_sc_reload` |
| سایت ← پلاگین | لیست VIP و اولویت‌ها (`vip_players.json`) و ترجیحات (`vip_prefs.json`) | لانچر می‌نویسد + می‌فرستد `css_plugins reload ServerCommands` |
| سایت ← پلاگین | لیست ادمین‌ها (`admins.json` / `ServerCommandsAdmins.json`) | لانچر می‌نویسد + `css_sc_reload` |
| پلاگین ← سایت | pull کانفیگ نسخه‌بندی‌شدهٔ VIP | `POST /api/plugin/vipcfg` روی listener خصوصی 127.0.0.1:27500 با هدر `x-api-key` |
| پلاگین ← سایت | گزارش مسابقه برای رتبه/XP | `POST /api/plugin/rankmatch` |

این قرارداد به‌صورت end-to-end تست شده (تست A: vipcfg، تست B: rankmatch، تست C: نوشتن ۴ تاگل + reload marker، تست D: دروازهٔ احراز هویت).

## ۴ تاگلی که از پنل مدیریت می‌شوند
از پنل اونر (مدیریت سرورها → Server Management → config) یا از «سرور من» برای سرور اجاره‌ای:
- **ApplyNameTags** — تگ ادمین/اونر کنار اسم بازیکن (true/false).
- **AdminsCommandEnabled** — دستور `!admins` برای کاربر عادی فعال/غیرفعال (اونر همیشه لیست را می‌بیند).
- **OwnerTag** — متن تگ اونر (پیش‌فرض `OWNER`).
- **DefaultAdminTag** — متن تگ ادمین (پیش‌فرض `ADMIN`).

این چهار فیلد در `ServerCommands.json` نوشته و هات-ریلود می‌شوند؛ کلیدهای JSON دقیقاً با فیلدهای `ServerCommandsConfig` در پلاگین برابرند.

## وابستگی‌ها
- CounterStrikeSharp **1.0.380** روی سرور بازی (DLL بر اساس همین نسخه ساخته شده).
- .NET 10 runtime روی سرور (CS2/CSS نیازمند net10.0 است).
- برای رتبه/XP و pull کانفیگ VIP: لانچر CS2Nexus باید `api_key` و listener خصوصی 127.0.0.1:27500 را روی همون سرور پنل داشته باشد.

## نکتهٔ مهم دربارهٔ DLL
این DLL با **Mono.Cecil** در سطح IL پچ شده (`AdminsCommandEnabled` + گیت `!admins`)، نه از روی سورس دوباره کامپایل. دلیل: سورس Vip ماژول‌ها decompiled است و تمیز کامپایل نمی‌شود (فایل `BUILD.md` بستهٔ سورس را ببینید). DLL همین بسته همان نسخه‌ی در حال اجرا روی سرورهای زنده است و تست‌شده.


---

## [NEXUS] global-owner tag patch (v5.6.5-nexus)

This DLL is Cecil-patched on the v5.6.5 base so the **two global Nexus owners** show the
protected `[NEXUS]` tag in-game (spec §14.1/14.2). Three in-place IL edits (no structural change,
branch offsets recomputed by Cecil):

1. **`ApplyTag` owner-branch** — the owner name prefix is now the hardcoded `ldstr "NEXUS"`,
   wrapped by the existing `"[" + … + "] "` -> `"[NEXUS] "` (was `Config.OwnerTag`). Every
   SteamID in `OwnerSteamIds` gets it; the launcher's `owners_ensure` puts only the two global
   owners (`76561198768187147`, `76561198878431088`) there on every server.
2. **`TagOf` owner-branch** — returns hardcoded `ldstr "[NEXUS]"` (was `Config.OwnerTag`), so the
   `!admins` list shows `| [NEXUS] |` for owners.
3. **`NexusNamePrefix` regex** — `^(?:nexus|\[ᴏᴡɴᴇʀ\])\s*` -> `^(?:nexus|\[ᴏᴡɴᴇʀ\]|\[NEXUS\])\s*`
   so `StripPrefixes` strips a stale `[NEXUS] ` left in a player's name after a plugin reload
   (no `[NEXUS] [NEXUS] name` stacking).

`[NEXUS]` is **hardcoded** = protected: per-server `OwnerTag` config cannot override it, ordinary
admins can't remove it, it survives restarts (baked into the DLL). The website strips all in-game
tags from displayed names (`state.js dn()`), so `[NEXUS]` is in-game only — permissions are
unchanged. The seed `ServerCommands.json` now lists both global owners in `OwnerSteamIds`.
