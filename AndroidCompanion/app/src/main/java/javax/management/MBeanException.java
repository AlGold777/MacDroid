package javax.management;

/**
 * Заглушка для совместимости на Android: Apache MINA SSHD опционально ссылается
 * на классы исключений javax.management, отсутствующие в стандартном Android SDK runtime.
 */
public class MBeanException extends JMException {
    private Exception exception;

    public MBeanException(Exception exception) {
        super();
        this.exception = exception;
    }

    public MBeanException(Exception exception, String message) {
        super(message);
        this.exception = exception;
    }

    public Exception getTargetException() {
        return exception;
    }

    @Override
    public Throwable getCause() {
        return exception;
    }
}
