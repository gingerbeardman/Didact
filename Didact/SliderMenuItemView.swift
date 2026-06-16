//
//  SliderMenuItemView.swift
//  BtnQ
//
//  A custom NSView used as an NSMenuItem.view for `range` controls: a title, a
//  live value readout, and a slider. The menu stays open while the slider is
//  dragged; value changes are reported through `onChange`.
//

import AppKit

@MainActor
final class SliderMenuItemView: NSView {
    private let slider = NSSlider()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Int) -> Void

    private let minValue: Int
    private let step: Int

    init(title: String, min: Int, max: Int, step: Int, value: Int,
         inset: CGFloat, enabled: Bool = true, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.minValue = min
        self.step = step
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))

        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = enabled ? .labelColor : .disabledControlTextColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = enabled ? .secondaryLabelColor : .disabledControlTextColor
        valueLabel.alignment = .right

        let clamped = Swift.min(Swift.max(value, min), max)
        slider.minValue = Double(min)
        slider.maxValue = Double(max)
        slider.doubleValue = Double(clamped)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.isEnabled = enabled
        slider.target = self
        slider.action = #selector(sliderChanged)

        titleLabel.stringValue = title
        valueLabel.stringValue = "\(clamped)"

        for v in [titleLabel, valueLabel, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func sliderChanged() {
        var value = Int(slider.doubleValue.rounded())
        if step > 1 {
            value = minValue + ((value - minValue) / step) * step
        }
        slider.doubleValue = Double(value)    // snap the round knob to the step (no tick marks)
        valueLabel.stringValue = "\(value)"   // label tracks live
        // Like the Linux app, write only the settled value — skip the stream of
        // intermediate values during a drag, which the d9 register dislikes.
        if NSApp.currentEvent?.type != .leftMouseDragged {
            onChange(value)
        }
    }
}
