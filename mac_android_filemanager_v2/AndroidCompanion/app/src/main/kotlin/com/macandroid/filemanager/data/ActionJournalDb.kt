package com.macandroid.filemanager.data

import androidx.room.*

@Entity(tableName = "action_receipts")
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

    @Query("SELECT * FROM action_receipts WHERE actionId = :actionId LIMIT 1")
    suspend fun getReceipt(actionId: String): ActionReceipt?

    @Query("UPDATE action_receipts SET status = :status WHERE actionId = :actionId")
    suspend fun updateStatus(actionId: String, status: String)
}

@Database(entities = [ActionReceipt::class], version = 1, exportSchema = false)
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
                ).build()
                INSTANCE = instance
                instance
            }
        }
    }
}
