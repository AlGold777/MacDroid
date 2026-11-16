package com.macandroid.filemanager.data

import androidx.room.*

@Entity(tableName = "action_receipts", indices = [Index(value = ["timestamp"])])
data class ActionReceipt(
    @PrimaryKey val actionId: String,
    val requestHash: String,
    val sourcePath: String,
    val targetPath: String,
    val status: String,
    val timestamp: Long
)

@Dao
interface ActionReceiptDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertReceipt(receipt: ActionReceipt)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertReceiptSync(receipt: ActionReceipt)

    @Query("SELECT * FROM action_receipts WHERE actionId = :actionId LIMIT 1")
    suspend fun getReceipt(actionId: String): ActionReceipt?

    @Query("UPDATE action_receipts SET status = :status WHERE actionId = :actionId")
    suspend fun updateStatus(actionId: String, status: String)

    // L24: ограничение роста журнала квитанций (записи старше порога удаляются)
    @Query("DELETE FROM action_receipts WHERE timestamp < :olderThan")
    suspend fun deleteOlderThan(olderThan: Long)
}

@Database(entities = [ActionReceipt::class], version = 2, exportSchema = false)
abstract class ActionJournalDb : RoomDatabase() {
    abstract fun actionReceiptDao(): ActionReceiptDao

    companion object {
        @Volatile
        private var INSTANCE: ActionJournalDb? = null

        fun getDatabase(context: android.content.Context): ActionJournalDb {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    ActionJournalDb::class.java,
                    "action_journal.db"
                )
                // L24: legacy-схема v1 без индекса: данные квитанций исторические,
                // безопасно пересоздать (информация дублирует файловую систему)
                .fallbackToDestructiveMigration()
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
