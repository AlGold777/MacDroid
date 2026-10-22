import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ModernDuplicateSpinnerView: View {
    var size: CGFloat = 44
    var lineWidth: CGFloat = 3.2
    var color: Color = .accentColor
    
    @State private var isSpinning: Bool = false
    
    public init(size: CGFloat = 44, lineWidth: CGFloat = 3.2, color: Color = .accentColor) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }
    
    public var body: some View {
        ZStack {
            // Тонкое фоновое кольцо трека
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            
            // Вращающаяся дуга со скруглёнными концами и угловым градиентом
            Circle()
                .trim(from: 0.0, to: 0.72)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            color.opacity(0.04),
                            color.opacity(0.55),
                            color
                        ]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(260)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    .linear(duration: 0.85)
                    .repeatForever(autoreverses: false),
                    value: isSpinning
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            isSpinning = true
        }
    }
}

public struct DuplicateProgressModalView: View {
    @ObservedObject var vm: DualPaneViewModel
    @State private var isCloseHovered: Bool = false
    @State private var isCancelHovered: Bool = false
    
    public init(vm: DualPaneViewModel) {
        self.vm = vm
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Верхняя панель со светофором
            HStack(spacing: 8) {
                // Красная кнопка закрытия/отмены
                Button(action: {
                    vm.cancelDuplicate()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.38, blue: 0.34))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                            )
                        
                        if isCloseHovered {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(Color.black.opacity(0.6))
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("Отменить")
                
                // Жёлтая кнопка (неактивна)
                Circle()
                    .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                
                // Серая кнопка (неактивна)
                Circle()
                    .fill(Color(white: 0.82))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            
            // Основное содержимое: современный спиннер + инфо
            HStack(alignment: .center, spacing: 14) {
                // Современный спиннер с иконкой внутри
                ZStack {
                    ModernDuplicateSpinnerView(size: 44, lineWidth: 3.2, color: Color.accentColor)
                    
                    itemIcon
                        .frame(width: 22, height: 22)
                }
                .frame(width: 44, height: 44)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.duplicateTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 8) {
                        // Полоса прогресса
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(NSColor.separatorColor).opacity(0.35))
                                    .frame(height: 6)
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor)
                                    .frame(width: max(0, min(barGeo.size.width, barGeo.size.width * CGFloat(vm.duplicateProgress))), height: 6)
                                    .animation(.linear(duration: 0.1), value: vm.duplicateProgress)
                            }
                        }
                        .frame(height: 6)
                        
                        // Кнопка отмены (крестик) справа от прогресс-бара
                        Button(action: {
                            vm.cancelDuplicate()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(isCancelHovered ? Color.primary : Color(NSColor.tertiaryLabelColor))
                        }
                        .buttonStyle(.plain)
                        .onHover { isCancelHovered = $0 }
                        .help("Отменить")
                    }
                    
                    Text(vm.duplicateSubtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 7)
    }
    
    @ViewBuilder
    private var itemIcon: some View {
        if vm.duplicateIsFolder {
            folderIcon
        } else if let path = vm.duplicateFirstTargetPath,
                  FileManager.default.fileExists(atPath: path) {
            let img = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "doc.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
        }
    }
    
    @ViewBuilder
    private var folderIcon: some View {
        if #available(macOS 11.0, *),
           let uti = UTType.folder as UTType? {
            let img = NSWorkspace.shared.icon(for: uti)
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.blue)
        }
    }
}
