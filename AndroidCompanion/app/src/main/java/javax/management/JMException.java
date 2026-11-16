package javax.management;

/**
 * Заглушка для совместимости на Android: Apache MINA SSHD опционально ссылается
 * на классы исключений javax.management, отсутствующие в стандартном Android SDK runtime.
 */
public class JMException extends Exception {
    public JMException() {
        super();
    }

    public JMException(String message) {
        super(message);
    }
}
