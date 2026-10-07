<div align="center">

# 🔒 Security Policy
### سیاست امنیتی

</div>

## 🇬🇧 English

CS2Nexus runs as **root** and manages game servers, so security reports are taken seriously.

### Supported versions
| Version | Supported |
|---|:---:|
| Latest `main` | ✅ |
| Older copies | ❌ — please run **Maintenance → Update launcher** first |

### Reporting a vulnerability
**Please do not open a public issue for security problems.**

1. Go to the **Security** tab of this repository
2. Click **Report a vulnerability** (private advisory)
3. Include: what you found, how to reproduce it, the launcher version/commit, and your Ubuntu version

You can expect an acknowledgement as soon as the maintainer is available, and a fix or mitigation for confirmed issues.

### In scope
- Privilege escalation or arbitrary command execution through the launcher, config file or JSON registries
- Unsafe path handling (`rm -rf`, symlink tricks, path traversal)
- Unsafe handling of downloaded plugins or launcher self-update
- Leaking secrets such as `GITHUB_TOKEN` or GSLT tokens

### Good practice for users
- ⚠️ Only point `NEXUS_REPO` at a repository **you control** — the self-update downloads a script that runs as root
- 🔑 Keep `/etc/cs2nexus.conf` readable by root only
- 🧱 Keep your firewall limited to the game ports you actually use

---

<div dir="rtl">

## 🇮🇷 فارسی

CS2Nexus با دسترسی **root** اجرا می‌شود و سرورهای بازی را مدیریت می‌کند؛ بنابراین گزارش‌های امنیتی جدی گرفته می‌شوند.

### نسخه‌های پشتیبانی‌شده
| نسخه | پشتیبانی |
|---|:---:|
| آخرین `main` | ✅ |
| نسخه‌های قدیمی | ❌ — ابتدا **Maintenance ← Update launcher** را اجرا کنید |

### گزارش آسیب‌پذیری
**لطفاً برای مشکلات امنیتی Issue عمومی باز نکنید.**

1. به تب **Security** همین مخزن بروید
2. روی **Report a vulnerability** بزنید (گزارش خصوصی)
3. این موارد را بنویسید: چه چیزی پیدا کرده‌اید، چطور بازتولید می‌شود، نسخه/کامیت لانچر و نسخهٔ Ubuntu

به‌محض امکان تأیید دریافت می‌کنید و برای مشکلات تأییدشده، رفع یا راه‌حل موقت ارائه می‌شود.

### موارد مشمول
- ارتقای دسترسی یا اجرای دستور دلخواه از طریق لانچر، فایل کانفیگ یا رجیستری‌های JSON
- مدیریت ناایمن مسیرها (`rm -rf`، ترفندهای symlink، path traversal)
- مدیریت ناایمن پلاگین‌های دانلودشده یا آپدیت خودکار لانچر
- نشت اطلاعات حساس مثل `GITHUB_TOKEN` یا توکن‌های GSLT

### توصیه برای کاربران
- ⚠️ `NEXUS_REPO` را فقط به مخزنی وصل کنید که **خودتان کنترل می‌کنید** — آپدیت خودکار اسکریپتی را دانلود می‌کند که با root اجرا می‌شود
- 🔑 فایل `/etc/cs2nexus.conf` فقط برای root قابل‌خواندن باشد
- 🧱 فایروال را فقط به پورت‌های بازی‌ای که استفاده می‌کنید محدود کنید

</div>