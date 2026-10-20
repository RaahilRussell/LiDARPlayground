//
//  ShareSheet.swift
//  test
//
//  Thin wrapper over UIActivityViewController so exported files can be saved to
//  the Mac (AirDrop / Files / etc.) from SwiftUI.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
