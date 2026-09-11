package javax.management;

public class ReflectionException extends JMException {
    private Exception exception;

    public ReflectionException(Exception exception) {
        super();
        this.exception = exception;
    }

    public ReflectionException(Exception exception, String message) {
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
