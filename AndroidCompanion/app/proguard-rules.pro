# ProGuard rules for MacDroid Android Companion v2.2 (ТЗ 6.1)

# Apache MINA SSHD (SFTP / SSH Server)
-keep class org.apache.sshd.** { *; }
-dontwarn org.apache.sshd.**
-dontwarn org.slf4j.**

# EdDSA Cryptography Provider (Ed25519 Keys)
-keep class net.i2p.crypto.eddsa.** { *; }
-dontwarn net.i2p.crypto.eddsa.**

# javax.management stubs for Android compatibility
-keep class javax.management.** { *; }
-dontwarn javax.management.**

# Kotlin Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory { *; }
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler { *; }
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}

# Android Architecture & Lifecycle
-keep class androidx.lifecycle.** { *; }
-dontwarn androidx.lifecycle.**
