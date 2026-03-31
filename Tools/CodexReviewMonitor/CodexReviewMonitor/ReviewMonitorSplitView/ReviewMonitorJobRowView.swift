//
//  ReviewMonitorJobRowView.swift
//  CodexReviewMonitor
//
//  Created by Kazuki Nakashima on 2026/03/31.
//

import SwiftUI
import CodexReviewMCP

struct ReviewMonitorJobRowView: View {
    var job: CodexReviewJob

    var body: some View {
        Label{
            VStack{
                HStack{
                    Text("Hello, World!")
                    Spacer(minLength: 0)
                }
                Text("Hello, World!")
                    .textScale(.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
        }icon:{
            Group{
                if job.status == .running{
                    ProgressView()
                }else{
                    Image(systemName:"circle.fill")
                        .foregroundStyle(job.status.color)
                }
            }
            .controlSize(.mini)
            .animation(.default,value:job.status)
        }
    }
}
extension CodexReviewJobStatus{
    var color:Color{
        return switch self{
        case .queued: .gray
        case .running: .gray
            
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .yellow
        }
    }
}

