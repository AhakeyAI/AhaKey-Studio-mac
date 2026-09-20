import CoreImage
import AppKit
import SwiftUI
import ImageIO

struct CloudAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var account = CloudAccountManager.shared
    @StateObject private var optimizer = AhaTypeTextOptimizer.shared
    @FocusState private var focusedLoginField: LoginField?

    private enum LoginField {
        case phone
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "text.718ee9ac9a1f", defaultValue: "云端账号 · AhaType"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) { dismiss() }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if account.isLoggedIn {
                        profileSection
                    } else {
                        loginSection
                    }

                    Divider()

                    ahaTypeSection
                }
                .padding(18)
            }
        }
        .alert(String(localized: "text.a416c44df8a8", defaultValue: "云端账号"), isPresented: Binding(
            get: { account.alertMessage != nil },
            set: { if !$0 { account.alertMessage = nil } }
        )) {
            Button(String(localized: "text.f867f3417859", defaultValue: "好"), role: .cancel) { account.alertMessage = nil }
        } message: {
            Text(account.alertMessage ?? "")
        }
        .onAppear {
            activateAhaKeyWindowForTextInput()
            optimizer.refreshFromDisk()
            if account.isLoggedIn {
                account.refreshProfile()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "text.dc57070dc8a7", defaultValue: "登录后可使用 AhaType 云端大模型整理。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(String(localized: "text.6f52cc94db65", defaultValue: "手机号"), text: $account.phone)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .phone)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
                .onSubmit { focusedLoginField = .password }

            SecureField(String(localized: "text.a621ab606db2", defaultValue: "密码"), text: $account.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .password)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .password
                }
                .onSubmit { account.login() }

            Toggle(String(localized: "text.6d1d717a83e1", defaultValue: "记住密码"), isOn: $account.rememberPassword)

            HStack(spacing: 10) {
                Button(String(localized: "text.1e2df9c3075a", defaultValue: "登录")) { account.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button(String(localized: "text.c4fb62202bad", defaultValue: "注册")) { account.register() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.profileSummary)
                .font(.callout)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                quotaRow(title: String(localized: "text.fd7b67c923cd", defaultValue: "每日"), value: account.quotaText("daily"))
                quotaRow(title: String(localized: "text.92845d3b531d", defaultValue: "每周"), value: account.quotaText("weekly"))
                quotaRow(title: String(localized: "text.68b21af949de", defaultValue: "每月"), value: account.quotaText("monthly"))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 10) {
                Button(String(localized: "text.aee887434131", defaultValue: "刷新")) { account.refreshProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button(String(localized: "text.e0351ba25410", defaultValue: "切换账号")) {
                    account.prepareForRelogin()
                    focusedLoginField = .phone
                }
                .buttonStyle(.bordered)
                .disabled(account.isBusy)
                Button(String(localized: "text.3ab8cc15939f", defaultValue: "退出登录")) { account.logout() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            rechargeSection

            HStack(spacing: 10) {
                TextField(String(localized: "text.b08f73bbb6c1", defaultValue: "免费券兑换码"), text: $account.couponCode)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "text.d094e6cb7e78", defaultValue: "兑换")) { account.redeemCoupon() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rechargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "text.f5a9ac8bd0ff", defaultValue: "充值订阅"))
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(CloudRechargePlan.allCases) { plan in
                    Button {
                        account.createWechatOrder(plan: plan)
                    } label: {
                        VStack(spacing: 3) {
                            Text(plan.title)
                                .font(.caption.weight(.semibold))
                            Text(account.priceText(for: plan))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(plan.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
                }
            }

            if let order = account.paymentOrder {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = makeQRCodeImage(from: order.paymentURL) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(order.plan.title) · \(order.amountText)")
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "text.3763dc74a6c4", defaultValue: "微信扫码完成支付，支付成功后会自动刷新额度。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "text.cac38006264b", defaultValue: "订单：\(String(describing: order.outTradeNo))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text(String(localized: "text.8944434aa7aa", defaultValue: "状态：\(String(describing: order.status))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(String(localized: "text.a605eea66e44", defaultValue: "复制支付链接")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(order.paymentURL, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "text.1d57f966aaaa", defaultValue: "刷新到账")) {
                            account.refreshCurrentPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                        .disabled(account.isBusy)

                        Button(String(localized: "text.be792396ebfb", defaultValue: "关闭订单")) {
                            account.clearPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var ahaTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { optimizer.isEnabled },
                set: { optimizer.setEnabled($0) }
            )) {
                Text(String(localized: "text.48b80dc3b758", defaultValue: "启用 AhaType 云端整理"))
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)

            Text(String(localized: "text.fd48629cd315", defaultValue: "开启后，macOS 原生语音转写完成后会先请求云端整理，再粘贴整理后的文本。未登录、过期或网络失败时会自动回退原始转写。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.lastQuotaSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func quotaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeQRCodeImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}


@MainActor
func activateAhaKeyWindowForTextInput() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.keyWindow?.makeKeyAndOrderFront(nil)
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
}
