import Foundation

/// Explicit format keys and count-aware plurals for the four app languages.
/// Placeholders are filled by String(format:), so user content is never translated or matched.
extension MirsaTr {
    enum PluralCategory: String { case zero, one, two, few, many, other }

    static func category(_ n: Int, _ lang: AppLanguage) -> PluralCategory {
        let n = abs(n)
        switch lang {
        case .arabic:
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if n == 2 { return .two }
            if n % 100 >= 3 && n % 100 <= 10 { return .few }
            if n % 100 >= 11 && n % 100 <= 99 { return .many }
            return .other
        case .english, .sorani, .kurmanji:
            return n == 1 ? .one : .other
        }
    }

    private static func code(_ l: AppLanguage) -> String {
        switch l { case .english: return "en"; case .arabic: return "ar"; case .sorani: return "ckb"; case .kurmanji: return "kmr" }
    }

    /// Explicit format key. Falls back Arabic, then the key itself (never a raw English sentence from a missing key).
    static func f(_ id: String, _ args: CVarArg...) -> String {
        let lang = AppLanguageStore.shared.current
        let row = formats[id]
        let fmt = row?[code(lang)] ?? row?["ar"] ?? id
        return String(format: fmt, arguments: args)
    }

    /// Count-aware plural. The count is always the first argument; extra args follow.
    static func p(_ id: String, _ n: Int, _ extra: CVarArg...) -> String {
        let lang = AppLanguageStore.shared.current
        let forms = plurals[id]?[code(lang)] ?? plurals[id]?["ar"] ?? [:]
        let cat = category(n, lang)
        let fmt = forms[cat.rawValue] ?? forms["other"] ?? id
        return String(format: fmt, arguments: [n] + extra)
    }

    static let formats: [String: [String: String]] = [
        "screenshot": ["en": "Screenshot %d of %d", "ar": "صورة %d من %d", "ckb": "وێنەی شاشە %d لە %d", "kmr": "Dîmena ekranê %d ji %d"],
        "expiresTomorrow": ["en": "%@ expires tomorrow. Open Mirsa to refresh it.", "ar": "%@ بتنتهي صلاحيته بكرا. افتح Mirsa وجدّده.", "ckb": "%@ سبەینێ بەسەر دەچێت. Mirsa بکەرەوە و نوێی بکەرەوە.", "kmr": "%@ sibê diqede. Mirsa veke û nû bike."],
        "received": ["en": "Received %@", "ar": "وصل %@", "ckb": "گەیشت %@", "kmr": "Hat %@"],
        "upToDate": ["en": "Mirsa is up to date (build %@).", "ar": "مرسى محدّث، معك آخر نسخة (%@).", "ckb": "Mirsa نوێکراوەتەوە (وەشانی بنیاتنان %@).", "kmr": "Mirsa nû ye (build %@)."],
        "build": ["en": "Build %@", "ar": "النسخة %@", "ckb": "بنیاتنان %@", "kmr": "Build %@"],
        "checks": ["en": "Checks for a newer build and installs it right away. Current build: %@.", "ar": "بيفحص إذا في نسخة أحدث وبيثبّتها فوراً. نسختك الحالية: %@.", "ckb": "دەگەڕێت بۆ وەشانێکی نوێتر و یەکسەر دایدەمەزرێنێت. وەشانی ئێستا: %@.", "kmr": "Li guhertoyeke nûtir digere û tavilê datîne. Guherta niha: %@."],
        "backups": ["en": "Mirsa also backs up automatically before updating or deleting the app, and keeps the last %d. Backups are in Files › Mirsa › Backups.", "ar": "Mirsa بياخد نسخة لحاله قبل التحديث أو الحذف، وبيحتفظ بآخر %d. النسخ بتلاقيها بالملفات › Mirsa › Backups.", "ckb": "Mirsa هەروەها پێش نوێکردنەوە یان سڕینەوەی ئەپ خۆکارانە پاڵپشتگیری دەکات و دوایین %d دەهێڵێتەوە. پاڵپشتگیرییەکان لە Files › Mirsa › Backups دان.", "kmr": "Mirsa her wiha beriya nûkirin an jêbirina sepanê bixweber paşgir digire û %d yên dawî dihêle. Paşgir di Files › Mirsa › Backups de ne."],
        "installedVer": ["en": "Installed: %@", "ar": "المنصّب: %@", "ckb": "دامەزراوە: %@", "kmr": "Hat sazkirin: %@"],
        "opens": ["en": "Opens %@ in Mirsa's container.", "ar": "بيفتح %@ بكونتينر Mirsa.", "ckb": "%@ لەناو کۆنتەینەری Mirsa دەکاتەوە.", "kmr": "%@ di konteynera Mirsa de vedike."],
        "tooMany": ["en": "Too many tries. Wait %@.", "ar": "محاولات كتير. استنى %@.", "ckb": "هەوڵی زۆرە. چاوەڕێ بکە %@.", "kmr": "Gelek ceribandin. %@ li bendê bimîne."],
        "page": ["en": "Page %d", "ar": "صفحة %d", "ckb": "لاپەڕە %d", "kmr": "Rûpel %d"],
        "shortcut": ["en": "In Shortcuts create a shortcut named %1$@. Add ‘Open App in Mirsa’ with App ID %2$@, or URL + Open URLs using %3$@. In Details choose Add to Home Screen, set the name and choose the shared icon. No configuration profile is needed.", "ar": "بالاختصارات اعمل اختصار باسم %1$@. ضيف Open App in Mirsa وحط App ID التالي %2$@، أو ضيف URL وبعده Open URLs بالرابط %3$@. من التفاصيل اختار إضافة للشاشة الرئيسية، سمّيه واختار الأيقونة يلي شاركتها. ما بدّه بروفايل.", "ckb": "لە Shortcuts کورتەڕێیەک بە ناوی %1$@ دروست بکە. Open App in Mirsa زیاد بکە لەگەڵ App ID %2$@، یان URL + Open URLs بە %3$@. لە وردەکاری Add to Home Screen هەڵبژێرە، ناو دابنێ و ئایکۆنی هاوبەش هەڵبژێرە. پڕۆفایلی ڕێکخستن پێویست نییە.", "kmr": "Di Shortcuts de kurtebirekê bi navê %1$@ çêke. Open App in Mirsa bi App ID %2$@ zêde bike, an URL + Open URLs bi %3$@. Di Details de Add to Home Screen hilbijêre, nav deyne û îkona parvekirî hilbijêre. Profîla veavakirinê ne hewce ye."],
        "pending": ["en": "Pending changes: %1$d added, %2$d removed. Applied on next export.", "ar": "تغييرات معلّقة: أُضيف %1$d، حُذف %2$d. بتنطبق عند التصدير.", "ckb": "گۆڕانکاری چاوەڕێکراو: %1$d زیادکرا، %2$d سڕایەوە. لە دەرهێنانی داهاتوو جێبەجێ دەبێت.", "kmr": "Guherînên li bendê: %1$d hat zêdekirin, %2$d hat jêbirin. Di derxistina dawîn de têne sepandin."],
        "sourceAnswered": ["en": "Source answered %d.", "ar": "السورس ردّ بـ %d.", "ckb": "سەرچاوە بە %d وەڵامی دایەوە.", "kmr": "Çavkaniyê bi %d bersiv da."],
        "walletCards": ["en": "Wallet Cards (%d)", "ar": "البطاقات (%d)", "ckb": "کارتەکان (%d)", "kmr": "Kart (%d)"],
        "fastMode": ["en": "Fast mode selected: only targets %1$@ with %2$@.", "ar": "الوضع السريع: يستهدف %1$@ مع %2$@ فقط.", "ckb": "دۆخی خێرا: تەنها %1$@ لەگەڵ %2$@ ئامانج دەگرێت.", "kmr": "Moda bilez: tenê %1$@ bi %2$@ armanc dike."],
        "key": ["en": "Key %@", "ar": "المفتاح %@", "ckb": "دوگمەی %@", "kmr": "Bişkoja %@"],
        "signedKept": ["en": "The signed IPA was kept: %@", "ar": "ملف الـIPA الموقّع انحفظ: %@", "ckb": "IPAی واژۆکراو هەڵگیرا: %@", "kmr": "IPA-ya îmzekirî hat parastin: %@"],
    ]

    static let plurals: [String: [String: [String: String]]] = [
        "days": [
            "en": ["one": "%d day", "other": "%d days"],
            "ar": ["zero": "%d يوم", "one": "يوم", "two": "يومان", "few": "%d أيام", "many": "%d يوماً", "other": "%d يوم"],
            "ckb": ["one": "%d ڕۆژ", "other": "%d ڕۆژ"],
            "kmr": ["one": "%d roj", "other": "%d roj"],
        ],
        "daysLeft": [
            "en": ["one": "%d day left", "other": "%d days left"],
            "ar": ["zero": "باقي %d يوم", "one": "باقي يوم", "two": "باقي يومين", "few": "باقي %d أيام", "many": "باقي %d يوم", "other": "باقي %d يوم"],
            "ckb": ["one": "%d ڕۆژ ماوە", "other": "%d ڕۆژ ماوە"],
            "kmr": ["one": "%d roj maye", "other": "%d roj mane"],
        ],
        "updates": [
            "en": ["one": "%d update found", "other": "%d updates found"],
            "ar": ["zero": "ما في تحديثات", "one": "في تحديث", "two": "في تحديثين", "few": "في %d تحديثات", "many": "في %d تحديث", "other": "في %d تحديث"],
            "ckb": ["one": "%d نوێکارییەک دۆزرایەوە", "other": "%d نوێکاری دۆزرایەوە"],
            "kmr": ["one": "%d nûvekirin hat dîtin", "other": "%d nûvekirin hatin dîtin"],
        ],
        "wrongPin": [
            "en": ["one": "Wrong PIN. %d try left.", "other": "Wrong PIN. %d tries left."],
            "ar": ["zero": "الرمز غلط.", "one": "الرمز غلط. باقي محاولة وحدة.", "two": "الرمز غلط. باقي محاولتين.", "few": "الرمز غلط. باقي %d محاولات.", "many": "الرمز غلط. باقي %d محاولة.", "other": "الرمز غلط. باقي %d محاولة."],
            "ckb": ["one": "PINی هەڵەیە. %d هەوڵ ماوە.", "other": "PINی هەڵەیە. %d هەوڵ ماون."],
            "kmr": ["one": "PIN şaş e. %d ceribandin maye.", "other": "PIN şaş e. %d ceribandin man."],
        ],
        "minutes": [
            "en": ["one": "%d min", "other": "%d min"],
            "ar": ["zero": "%d دقيقة", "one": "دقيقة", "two": "دقيقتين", "few": "%d دقائق", "many": "%d دقيقة", "other": "%d دقيقة"],
            "ckb": ["one": "%d خولەک", "other": "%d خولەک"],
            "kmr": ["one": "%d xulek", "other": "%d xulek"],
        ],
        "seconds": [
            "en": ["one": "%d s", "other": "%d s"],
            "ar": ["zero": "%d ثانية", "one": "ثانية", "two": "ثانيتين", "few": "%d ثوانٍ", "many": "%d ثانية", "other": "%d ثانية"],
            "ckb": ["one": "%d چرکە", "other": "%d چرکە"],
            "kmr": ["one": "%d çirk", "other": "%d çirk"],
        ],
        "wallpapersImported": [
            "en": ["one": "%d Wallpaper Imported", "other": "%d Wallpapers Imported"],
            "ar": ["zero": "لا خلفيات مستوردة", "one": "تم استيراد خلفية", "two": "تم استيراد خلفيتين", "few": "تم استيراد %d خلفيات", "many": "تم استيراد %d خلفية", "other": "تم استيراد %d خلفية"],
            "ckb": ["one": "%d وێنەی پشتەوە هاوردەکرا", "other": "%d وێنەی پشتەوە هاوردەکران"],
            "kmr": ["one": "%d wallpaper hat têxistin", "other": "%d wallpaper hatin têxistin"],
        ],
        "flashWallpapers": [
            "en": ["one": "Flash %d Wallpaper", "other": "Flash %d Wallpapers"],
            "ar": ["zero": "تنفيذ %d خلفية", "one": "تنفيذ خلفية", "two": "تنفيذ خلفيتين", "few": "تنفيذ %d خلفيات", "many": "تنفيذ %d خلفية", "other": "تنفيذ %d خلفية"],
            "ckb": ["one": "نووسینی %d وێنەی پشتەوە", "other": "نووسینی %d وێنەی پشتەوە"],
            "kmr": ["one": "%d wallpaper bisepîne", "other": "%d wallpaperan bisepîne"],
        ],
        "items": [
            "en": ["one": "%d item", "other": "%d items"],
            "ar": ["zero": "لا عناصر", "one": "عنصر", "two": "عنصران", "few": "%d عناصر", "many": "%d عنصراً", "other": "%d عنصر"],
            "ckb": ["one": "%d بڕگە", "other": "%d بڕگە"],
            "kmr": ["one": "%d tişt", "other": "%d tişt"],
        ],
        "addons": [
            "en": ["one": "%d add-on", "other": "%d add-ons"],
            "ar": ["zero": "لا إضافات", "one": "إضافة", "two": "إضافتان", "few": "%d إضافات", "many": "%d إضافة", "other": "%d إضافة"],
            "ckb": ["one": "%d زیادکراو", "other": "%d زیادکراو"],
            "kmr": ["one": "%d lêzêdekirin", "other": "%d lêzêdekirin"],
        ],
        "removeExpired": [
            "en": ["one": "Remove %d expired", "other": "Remove %d expired"],
            "ar": ["zero": "احذف %d منتهية", "one": "احذف المنتهي", "two": "احذف المنتهيين", "few": "احذف %d منتهية", "many": "احذف %d منتهية", "other": "احذف %d منتهية"],
            "ckb": ["one": "سڕینەوەی %d بەسەرچوو", "other": "سڕینەوەی %d بەسەرچوو"],
            "kmr": ["one": "%d qediyayî jê bibe", "other": "%d qediyayî jê bibe"],
        ],
        "codeFiles": [
            "en": ["one": "%d code file", "other": "%d code files"],
            "ar": ["zero": "لا ملفات كود", "one": "ملف كود", "two": "ملفا كود", "few": "%d ملفات كود", "many": "%d ملف كود", "other": "%d ملف كود"],
            "ckb": ["one": "%d فایلی کۆد", "other": "%d فایلی کۆد"],
            "kmr": ["one": "%d pelê kodê", "other": "%d pelên kodê"],
        ],
        "showAllKeys": [
            "en": ["one": "Show %d key", "other": "Show all %d keys"],
            "ar": ["zero": "عرض المفاتيح", "one": "عرض المفتاح", "two": "عرض المفتاحين", "few": "عرض كل المفاتيح %d", "many": "عرض كل المفاتيح %d", "other": "عرض كل المفاتيح %d"],
            "ckb": ["one": "پیشاندانی %d کلیل", "other": "پیشاندانی هەموو %d کلیلەکان"],
            "kmr": ["one": "%d mifte nîşan bide", "other": "Hemû %d miftan nîşan bide"],
        ],
    ]
}
