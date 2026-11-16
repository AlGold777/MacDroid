import AppKit
import SwiftUI

/// Поддерживаемые сервисы быстрой отправки
public enum ShareTarget: String, Sendable, CaseIterable {
    case telegram = "Telegram"
    case whatsapp = "WhatsApp"
    case gmail = "Gmail"
    
    public var title: String {
        switch self {
        case .telegram: return "Telegram"
        case .whatsapp: return "WhatsApp"
        case .gmail: return "Gmail"
        }
    }
    
    public var tooltip: String {
        switch self {
        case .telegram: return "Поделиться в Telegram"
        case .whatsapp: return "Поделиться в WhatsApp"
        case .gmail: return "Отправить через Gmail / Почту"
        }
    }
}

/// Векторная и нативная отрисовка иконок Telegram, WhatsApp и Gmail
public enum ShareIconDrawer {
    
    /// Получение нативной иконки приложения macOS по Bundle ID или пути установки
    private static func appIcon(bundleIds: [String], fallbackPaths: [String], size: CGFloat) -> NSImage? {
        let ws = NSWorkspace.shared
        for bid in bundleIds {
            if let url = ws.urlForApplication(withBundleIdentifier: bid) {
                let icon = ws.icon(forFile: url.path)
                return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    return true
                }
            }
        }
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                let icon = ws.icon(forFile: path)
                return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                    return true
                }
            }
        }
        return nil
    }
    
    public static func telegramImage(size: CGFloat = 20) -> NSImage {
        // Нативная иконка Telegram macOS
        if let icon = appIcon(
            bundleIds: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"],
            fallbackPaths: ["/Applications/Telegram.app"],
            size: size
        ) {
            return icon
        }
        
        // Векторный fallback
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(red: 0.165, green: 0.671, blue: 0.933, alpha: 1.0).setFill()
            circle.fill()
            
            let s = size / 20.0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 15.2 * s, y: 14.2 * s))
            path.line(to: NSPoint(x: 5.0 * s, y: 10.0 * s))
            path.line(to: NSPoint(x: 8.5 * s, y: 7.8 * s))
            path.line(to: NSPoint(x: 13.0 * s, y: 12.0 * s))
            path.line(to: NSPoint(x: 9.0 * s, y: 7.5 * s))
            path.line(to: NSPoint(x: 8.8 * s, y: 5.2 * s))
            path.line(to: NSPoint(x: 11.0 * s, y: 7.2 * s))
            path.line(to: NSPoint(x: 15.2 * s, y: 14.2 * s))
            path.close()
            
            NSColor.white.setFill()
            path.fill()
            return true
        }
    }
    
    public static func whatsAppImage(size: CGFloat = 20) -> NSImage {
        // Нативная иконка WhatsApp macOS
        if let icon = appIcon(
            bundleIds: ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsApp.desktop"],
            fallbackPaths: ["/Applications/WhatsApp.app"],
            size: size
        ) {
            return icon
        }
        
        // Векторный fallback
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: 1.0).setFill()
            circle.fill()
            
            let s = size / 20.0
            // Белое речевое облако
            let bubble = NSBezierPath()
            let bRect = NSRect(x: 4.5 * s, y: 4.5 * s, width: 11.0 * s, height: 11.0 * s)
            bubble.appendOval(in: bRect)
            
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 5.5 * s, y: 6.5 * s))
            tail.line(to: NSPoint(x: 3.4 * s, y: 3.4 * s))
            tail.line(to: NSPoint(x: 7.5 * s, y: 5.2 * s))
            tail.close()
            bubble.append(tail)
            
            NSColor.white.setFill()
            bubble.fill()
            
            // Зелёный силуэт телефонной трубки внутри облака
            let phone = NSBezierPath()
            phone.move(to: NSPoint(x: 7.2 * s, y: 8.0 * s))
            phone.curve(to: NSPoint(x: 8.5 * s, y: 12.0 * s), controlPoint1: NSPoint(x: 6.8 * s, y: 9.8 * s), controlPoint2: NSPoint(x: 7.5 * s, y: 11.2 * s))
            phone.line(to: NSPoint(x: 9.8 * s, y: 11.2 * s))
            phone.line(to: NSPoint(x: 9.2 * s, y: 9.8 * s))
            phone.line(to: NSPoint(x: 8.5 * s, y: 10.0 * s))
            phone.curve(to: NSPoint(x: 8.0 * s, y: 8.8 * s), controlPoint1: NSPoint(x: 8.2 * s, y: 9.5 * s), controlPoint2: NSPoint(x: 8.0 * s, y: 9.0 * s))
            phone.curve(to: NSPoint(x: 9.2 * s, y: 7.8 * s), controlPoint1: NSPoint(x: 8.2 * s, y: 8.2 * s), controlPoint2: NSPoint(x: 8.8 * s, y: 7.8 * s))
            phone.line(to: NSPoint(x: 9.0 * s, y: 7.0 * s))
            phone.line(to: NSPoint(x: 7.8 * s, y: 6.8 * s))
            phone.curve(to: NSPoint(x: 7.2 * s, y: 8.0 * s), controlPoint1: NSPoint(x: 7.4 * s, y: 7.0 * s), controlPoint2: NSPoint(x: 7.2 * s, y: 7.5 * s))
            phone.close()
            
            NSColor(red: 0.145, green: 0.827, blue: 0.400, alpha: 1.0).setFill()
            phone.fill()
            return true
        }
    }
    
    public static func gmailImage(size: CGFloat = 20) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.white.setFill()
            circle.fill()
            NSColor(white: 0.85, alpha: 1.0).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            
            let s = size / 20.0
            let mPath = NSBezierPath()
            let left: CGFloat = 4.5 * s
            let right: CGFloat = 15.5 * s
            let top: CGFloat = 14.5 * s
            let bottom: CGFloat = 5.5 * s
            let midX: CGFloat = 10.0 * s
            let foldY: CGFloat = 9.5 * s
            
            mPath.move(to: NSPoint(x: left, y: bottom))
            mPath.line(to: NSPoint(x: left, y: top))
            mPath.line(to: NSPoint(x: midX, y: foldY))
            mPath.line(to: NSPoint(x: right, y: top))
            mPath.line(to: NSPoint(x: right, y: bottom))
            mPath.line(to: NSPoint(x: right - 1.8 * s, y: bottom))
            mPath.line(to: NSPoint(x: right - 1.8 * s, y: top - 2.8 * s))
            mPath.line(to: NSPoint(x: midX, y: foldY + 0.5 * s))
            mPath.line(to: NSPoint(x: left + 1.8 * s, y: top - 2.8 * s))
            mPath.line(to: NSPoint(x: left + 1.8 * s, y: bottom))
            mPath.close()
            
            NSColor(red: 0.918, green: 0.263, blue: 0.208, alpha: 1.0).setFill()
            mPath.fill()
            
            // Тонкая красная линия сверху
            let tBar = NSRect(x: left, y: top - 1.0 * s, width: right - left, height: 1.0 * s)
            let tPath = NSBezierPath(rect: tBar)
            NSColor(red: 0.918, green: 0.263, blue: 0.208, alpha: 1.0).setFill()
            tPath.fill()
            
            // Нижняя красная полоса
            let bBar = NSRect(x: left, y: bottom, width: right - left, height: 1.6 * s)
            let bPath = NSBezierPath(rect: bBar)
            NSColor(red: 0.82, green: 0.2, blue: 0.15, alpha: 1.0).setFill()
            bPath.fill()
            return true
        }
    }
}

/// Кнопка с иконкой для пункта меню
final class ShareIconButton: NSView {
    let target: ShareTarget
    let icon: NSImage
    let onClick: () -> Void
    private var isHovered: Bool = false
    
    init(target: ShareTarget, icon: NSImage, toolTipText: String, onClick: @escaping () -> Void) {
        self.target = target
        self.icon = icon
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = toolTipText
        
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 22, height: 22)
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
    
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick()
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if isHovered {
            let hoverRect = bounds.insetBy(dx: 1, dy: 1)
            let hoverPath = NSBezierPath(roundedRect: hoverRect, xRadius: 4, yRadius: 4)
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            hoverPath.fill()
        }
        
        let iconSize: CGFloat = 18
        let iconRect = NSRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        icon.draw(in: iconRect)
    }
}

/// Горизонтальная строка кнопок «Поделиться» (Telegram, WhatsApp, Gmail) для контекстного меню NSMenu
public final class ShareRowMenuView: NSView {
    private let targets: [ShareTarget] = [.telegram, .whatsapp, .gmail]
    
    public init(onSelectTarget: @escaping (ShareTarget) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 28))
        
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 22)
        ])
        
        for target in targets {
            let img: NSImage
            switch target {
            case .telegram:
                img = ShareIconDrawer.telegramImage(size: 20)
            case .whatsapp:
                img = ShareIconDrawer.whatsAppImage(size: 20)
            case .gmail:
                img = ShareIconDrawer.gmailImage(size: 20)
            }
            
            let btn = ShareIconButton(target: target, icon: img, toolTipText: target.tooltip) { [weak self] in
                self?.enclosingMenuItem?.menu?.cancelTracking()
                DispatchQueue.main.async {
                    onSelectTarget(target)
                }
            }
            stack.addArrangedSubview(btn)
        }
    }
    
    required init?(coder: NSCoder) { fatalError() }
}
