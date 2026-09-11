# ProGuard rules for MacDroid Android Companion

# Apache MINA SSHD (SFTP / SSH Server)
-keep class org.apache.sshd.** { *; }
-dontwarn org.apache.sshd.**

# BouncyCastle Cryptography Provider (Ed25519 & RSA Keys)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# Room Database & SQLite
-keep class androidx.room.** { *; }
-dontwarn androidx.room.**
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class * { *; }
-keep @androidx.room.Dao interface * { *; }

# Kotlin Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory { *; }
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler { *; }
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}

# Android Architecture & Lifecycle
-keep class androidx.lifecycle.** { *; }
-dontwarn androidx.lifecycle.**
