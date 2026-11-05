# NexusVIP (Normal VIP, phase 1)

این نسخه فقط دو دستور owner دارد: `!addvip` و `!vip`. Advanced VIP و بقیه‌ی قابلیت‌ها در فاز بعدی.

## دستورات

- `!addvip [name]&<steamid64> <level> [days]`
  - مثال: `!addvip Ali&76561198000000000 gold 30`
  - مثال بدون نام: `!addvip 76561198000000000 2 7`
  - level: `bronze|silver|gold|platinum` یا `1-4`
  - days اختیاری است (پیش‌فرض ۳۰، حداکثر ۳۶۵۰)
  - اگر VIP هنوز فعال باشد، مدت جدید روی تاریخ انقضای فعلی اضافه می‌شود (کوتاه نمی‌شود).
- `!vip`: لیست VIPهای همین سرور، با وضعیت و تاریخ انقضا.

فقط بازیکنی که یکی از `OwnerFlags` را دارد (پیش‌فرض `@css/root`) و کنسول سرور می‌توانند از این دستورات استفاده کنند.

## قوانین سطح

هر سطح تمام قابلیت‌های سطوح پایین‌تر را دارد. نقشه‌ی قابلیت‌ها در `Models/VipFeature.cs` است.

## نصب

1. `CounterStrikeSharp.API` را در `NexusVIP.csproj` روی نسخه‌ی نصب‌شده تنظیم کن.
2. `dotnet publish -c Release` بزن.
3. پوشه‌ی `NexusVIP` را داخل `addons/counterstrikesharp/plugins/` کپی کن.
4. فایل `NexusVIP.json` را در کنار DLL بگذار و `OwnerFlags` را با فلگ owner همین سرور تنظیم کن.

## داده و نگهداری

- `vip_players.json`: لیست memberships همین سرور (هر سرور نسخه‌ی جدا دارد)
- `vip_audit.log`: ثبت هر GRANT/UPDATE/REMOVE همراه با actor
- اگر فایل خراب باشد، قبل از هر تغییر نسخه‌ی `corrupt-...` ساخته می‌شود.

## یادداشت‌های باز

- این کد کامپایل و تست نشده (در محیط ما NuGet و CSS نصب نیست).
- `AdminManager.AddPlayerPermissions` و `RemovePlayerPermissions` باید با CSS 1.0.379 تطبیق داده شوند (در ServerCommands استفاده نشده‌اند).
- ServerCommands تغییر نمی‌کند. ارتباط با آن فقط از راه فلگ‌های دسترسی CSS است:
  سطح VIP که VoteKick دارد، فلگ `@nepentii/votekick` می‌گیرد و ServerCommands (در `HasPerm`) همین فلگ را چک می‌کند.
  این کار در `NexusVIP.json` با `ServerCommandsBridge` خاموش می‌شود.
- اگر بازیکنی از قبل همان فلگ را از `admins.json` داشته باشد، NexusVIP آن را حذف نمی‌کند.
- همگام‌سازی هر ۶۰ ثانیه انجام می‌شود، پس اگر ServerCommands با `sc_reload` دسترسی‌ها را بازنشانی کند، ظرف یک دقیقه برمی‌گردند.
- CounterStrikeSharp.API روی 1.0.379 و net10.0 تنظیم شده (همان csproj ServerCommands).
