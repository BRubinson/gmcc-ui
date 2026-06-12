//
//  Item.swift
//  GMVibes
//
//  Created by Bryce Rubinson on 6/12/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
