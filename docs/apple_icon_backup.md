# Резервная копия иконки «Яблоко» (Apple Logo)

Документ создан для сохранения кода и графических ресурсов контурной иконки Apple (Mac), если потребуется вернуть её вместо текущей иконки компьютера/ноутбука.

---

## 1. Резервные файлы ассетов
Файлы иконки сохранены в проекте:
- Векторный SVG: `MacHost/Resources/toolbar_apple.svg`
- Растровый шаблон PNG (150×150): `MacHost/Resources/toolbar_apple.png`

---

## 2. Исходный векторный SVG-код яблока

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M12 20.94c1.5 0 2.75 1.06 4 1.06 3 0 6-8 6-12.22A4.91 4.91 0 0 0 17 5c-2.22 0-4 1.44-5 2-1-.56-2.78-2-5-2a4.9 4.9 0 0 0-5 4.78C2 14 5 22 8 22c1.25 0 2.5-1.06 4-1.06Z"></path>
    <path d="M10 2c1 .5 2 2 2 5"></path>
</svg>
```

---

## 3. Исходный фрагмент кода Swift в `PaneView.swift`

Для восстановления яблока в коде `MacHost/Sources/MacHostCore/UI/Views/PaneView.swift`:

```swift
private let toolbarMacSvgString = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M12 20.94c1.5 0 2.75 1.06 4 1.06 3 0 6-8 6-12.22A4.91 4.91 0 0 0 17 5c-2.22 0-4 1.44-5 2-1-.56-2.78-2-5-2a4.9 4.9 0 0 0-5 4.78C2 14 5 22 8 22c1.25 0 2.5-1.06 4-1.06Z"></path>
    <path d="M10 2c1 .5 2 2 2 5"></path>
</svg>
"""

public struct MacToolbarIconView: View {
    public var size: CGFloat = 20
    
    public init(size: CGFloat = 20) {
        self.size = size
    }
    
    public var body: some View {
        if let img = loadToolbarDriveIcon(named: "toolbar_mac") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.85, weight: .regular))
        }
    }
}
```

---

## 4. Быстрое восстановление из терминала

Чтобы вернуть яблоко обратно:
```bash
cp MacHost/Resources/toolbar_apple.svg MacHost/Resources/toolbar_mac.svg
cp MacHost/Resources/toolbar_apple.png MacHost/Resources/toolbar_mac.png
./scripts/build_macos_app.sh
```
