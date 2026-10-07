<div align="center">

# 🛠️ Contributing to CS2Nexus
### مشارکت در CS2Nexus

</div>

## 🇬🇧 English

Thanks for helping make CS2Nexus better! 🎉

### 🐛 Reporting bugs
Open an issue and include:
- Ubuntu version and CS2 build
- Steps to reproduce
- Relevant output from **Log Viewer** or `<server>/logs/console.log`
- ⚠️ **Remove** tokens (GSLT, `GITHUB_TOKEN`) and private IPs before pasting

### 💡 Suggesting features
Open an issue describing the problem you want solved, not only the solution.

### 🔧 Pull requests
1. Fork the repository and create a branch
2. Keep the script's safety rules: validate paths, write JSON atomically, never overwrite real local plugin files
3. Check syntax before submitting:
   ```bash
   bash -n nexus.sh
   shellcheck nexus.sh   # if installed
   ```
4. Test on Ubuntu 22.04 with at least one server
5. Describe **what** changed and **why**

### 🔌 Adding a plugin to the Plugin Browser
Add the plugin to the `plugins` folder of this repository (or add its GitHub release source via `EXTRA_PLUGIN_REPOS`) and open a pull request.

---

<div dir="rtl">

## 🇮🇷 فارسی

ممنون که به بهتر شدن CS2Nexus کمک می‌کنید! 🎉

### 🐛 گزارش باگ
یک Issue باز کنید و این‌ها را بنویسید:
- نسخهٔ Ubuntu و بیلد CS2
- مراحل بازتولید
- خروجی مرتبط از **Log Viewer** یا `<server>/logs/console.log`
- ⚠️ قبل از چسباندن، توکن‌ها (GSLT، `GITHUB_TOKEN`) و آی‌پی‌های خصوصی را **پاک کنید**

### 💡 پیشنهاد قابلیت
یک Issue باز کنید و مشکلی را که می‌خواهید حل شود شرح دهید، نه فقط راه‌حل را.

### 🔧 Pull Request
1. مخزن را Fork کنید و یک branch بسازید
2. قوانین ایمنی اسکریپت را رعایت کنید: اعتبارسنجی مسیرها، نوشتن اتمیک JSON، هرگز بازنویسی فایل‌های واقعی پلاگین
3. قبل از ارسال، سینتکس را بررسی کنید:
   ```bash
   bash -n nexus.sh
   shellcheck nexus.sh   # در صورت نصب بودن
   ```
4. روی Ubuntu 22.04 و با حداقل یک سرور تست کنید
5. توضیح دهید **چه** چیزی و **چرا** تغییر کرده

### 🔌 افزودن پلاگین به مرورگر پلاگین
پلاگین را به پوشهٔ `plugins` این مخزن اضافه کنید (یا منبع release گیت‌هابش را با `EXTRA_PLUGIN_REPOS` معرفی کنید) و Pull Request بدهید.

</div>
