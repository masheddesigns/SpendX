# Proguard rules for SpendX app.
# Generated automatically by R8 / Android Gradle plugin for google_mlkit_text_recognition plugin.

-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# SQLCipher native JNI preservation rules for release R8 minification
-keep class net.sqlcipher.** { *; }
-dontwarn net.sqlcipher.**
-keep class io.requery.android.database.** { *; }
-dontwarn io.requery.android.database.**
