//
//  GYRollingNoticeView.swift
//  RollingNotice-Swift
//
//  Created by qm on 2017/12/13.
//  Copyright © 2017年 qm. All rights reserved.
//

import UIKit

// MARK: - GYRollingNoticeViewDataSource

@objc public protocol GYRollingNoticeViewDataSource: NSObjectProtocol {
    func numberOfRowsFor(roolingView: GYRollingNoticeView) -> Int
    func rollingNoticeView(roolingView: GYRollingNoticeView, cellAtIndex index: Int)
        -> GYNoticeViewCell
}

// MARK: - GYRollingNoticeViewDelegate

@objc public protocol GYRollingNoticeViewDelegate: NSObjectProtocol {
    @objc optional func rollingNoticeView(_ roolingView: GYRollingNoticeView, didClickAt index: Int)
}

// MARK: - GYRollingNoticeViewStatus

public enum GYRollingNoticeViewStatus: UInt {
    case idle, working, pause
}

// MARK: - GYRollingNoticeView

open class GYRollingNoticeView: UIView {
    open weak var dataSource: GYRollingNoticeViewDataSource?
    open weak var delegate: GYRollingNoticeViewDelegate?
    open var stayInterval = 2.0
    open private(set) var status: GYRollingNoticeViewStatus = .idle
    open var currentIndex: Int {
        guard let count = (dataSource?.numberOfRowsFor(roolingView: self)) else {
            return 0
        }

        if _cIdx > count - 1 {
            _cIdx = 0
        }
        return _cIdx
    }

    private var _cIdx = 0
    private var _needTryRoll = false

    // MARK: private properties

    private lazy var cellClsDict: Dictionary = { () -> [String: Any] in
        var tempDict = [String: Any]()
        return tempDict
    }()

    private lazy var reuseCells: Array = { () -> [GYNoticeViewCell] in
        var tempArr = [GYNoticeViewCell]()
        return tempArr
    }()

    private var timer: Timer?
    private var currentCell: GYNoticeViewCell?
    private var willShowCell: GYNoticeViewCell?
    private var isAnimating = false

    // MARK: -

    open func register(_ cellClass: Swift.AnyClass?, forCellReuseIdentifier identifier: String) {
        cellClsDict[identifier] = cellClass
    }

    open func register(_ nib: UINib?, forCellReuseIdentifier identifier: String) {
        cellClsDict[identifier] = nib
    }

    open func dequeueReusableCell(withIdentifier identifier: String) -> GYNoticeViewCell? {
        // 添加安全检查，确保identifier不为空
        guard !identifier.isEmpty else {
            return nil
        }

        // 先尝试从重用池中获取cell
        for cell in reuseCells {
            guard let reuseIdentifier = cell.reuseIdentifier else {
                continue
            }
            if reuseIdentifier.elementsEqual(identifier) {
                // 找到后从重用池中移除
                if let index = reuseCells.firstIndex(of: cell) {
                    reuseCells.remove(at: index)
                }
                return cell
            }
        }

        // 如果重用池中没有可用的cell，创建新的cell
        if let cellCls = cellClsDict[identifier] {
            if let nib = cellCls as? UINib {
                let arr = nib.instantiate(withOwner: nil, options: nil)
                guard let cell = arr.first as? GYNoticeViewCell else {
                    return nil
                }
                
                // 现在CustomNoticeCell和CustomNoticeCell2已经在awakeFromNib中设置了reuseIdentifier
                // 如果仍然没有设置，输出警告但继续使用该cell
                if cell.reuseIdentifier == nil && GYRollingDebugLog {
                    print("警告: 从Xib加载的cell没有设置reuseIdentifier，可能会影响cell重用功能")
                    print("提示: 请在cell的awakeFromNib方法中调用setup(withReuseIdentifier:)方法设置标识符")
                }
                
                return cell
            }

            if let noticeCellCls = cellCls as? GYNoticeViewCell.Type {
                let cell = noticeCellCls.self.init(reuseIdentifier: identifier)
                return cell
            }
        }
        return nil
    }

    open func reloadDataAndStartRoll() {
        stopRoll()
        guard let count = dataSource?.numberOfRowsFor(roolingView: self), count > 0 else {
            return
        }

        layoutCurrentCellAndWillShowCell()

        guard count >= 2 else {
            return
        }

        timer = Timer.scheduledTimer(
            timeInterval: stayInterval, target: self,
            selector: #selector(GYRollingNoticeView.timerHandle), userInfo: nil, repeats: true
        )
        if let timer {
            RunLoop.current.add(timer, forMode: .common)
        }
        resume()
    }

    open func stopRoll() {
        // 确保在主线程执行UI操作
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopRoll()
            }
            return
        }
        
        // 先停止定时器，防止在清理过程中触发新的动画
        if let rollTimer = timer {
            rollTimer.invalidate()
            timer = nil
        }

        status = .idle
        isAnimating = false
        _cIdx = 0

        // 先保存引用，再清空属性，最后执行移除操作
        // 这样可以避免可能的野指针问题
        let tempCurrentCell = currentCell
        let tempWillShowCell = willShowCell

        currentCell = nil
        willShowCell = nil

        // 移除子视图
        tempCurrentCell?.removeFromSuperview()
        tempWillShowCell?.removeFromSuperview()
        
        // 清空重用池
        for cell in reuseCells {
            cell.removeFromSuperview()
        }
        reuseCells.removeAll()
    }

    open func pause() {
        if let timer {
            timer.fireDate = Date.distantFuture
            status = .pause
        }
    }

    open func resume() {
        if let timer {
            timer.fireDate = Date.distantPast
            status = .working
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupNoticeViews()
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupNoticeViews()
    }

    override open func touchesBegan(_: Set<UITouch>, with _: UIEvent?) {}

    override open func layoutSubviews() {
        super.layoutSubviews()
        if _needTryRoll {
            reloadDataAndStartRoll()
            _needTryRoll = false
        }
    }

    deinit {
        stopRoll()
    }
}

// MARK: private funcs

private extension GYRollingNoticeView {
    @objc func timerHandle() {
        if isAnimating {
            return
        }

        guard let dataSource,
              dataSource.numberOfRowsFor(roolingView: self) > 0
        else {
            return
        }

        layoutCurrentCellAndWillShowCell()

        guard let currentCell = self.currentCell, let willShowCell = self.willShowCell else {
            return
        }

        let width = frame.size.width
        let height = frame.size.height

        isAnimating = true
        
        // 保留对当前执行动画的cell的强引用，确保动画过程中不会被释放
        let animatingCurrentCell = currentCell
        let animatingWillShowCell = willShowCell
        
        UIView.animate(
            withDuration: 0.5,
            animations: {
                animatingCurrentCell.frame = CGRect(x: 0, y: -height, width: width, height: height)
                animatingWillShowCell.frame = CGRect(x: 0, y: 0, width: width, height: height)
            }
        ) { [weak self] finished in
            guard let self = self, finished else {
                return
            }

            // 检查动画完成时，当前cell和即将显示的cell是否仍然是原来的引用
            // 这可以防止在动画过程中cell被改变导致的问题
            if self.currentCell === animatingCurrentCell && self.willShowCell === animatingWillShowCell {
                // 确保只有在动画正常完成时才进行cell的切换
                let cellToReuse = self.currentCell
                self.currentCell = self.willShowCell
                self.willShowCell = nil
                
                // 修复条件绑定问题
                if let cellToReuse = cellToReuse {
                    // 先从视图层次结构中移除，然后再加入重用池
                    cellToReuse.removeFromSuperview()
                    self.reuseCells.append(cellToReuse)
                }
            } else {
                // 如果引用已变化，可能是stopRoll被调用或其他异常情况
                // 只清理不再使用的视图，避免引用冲突
                animatingCurrentCell.removeFromSuperview()
                // 不要将其加入重用池，因为当前状态可能已不一致
            }
            
            self.isAnimating = false
            self._cIdx += 1
        }
    }

    func layoutCurrentCellAndWillShowCell() {
        guard let dataSource else {
            return
        }
        let count = dataSource.numberOfRowsFor(roolingView: self)
        guard count > 0 else {
            return
        }

        if _cIdx > count - 1 {
            _cIdx = 0
        }

        var willShowIndex = _cIdx + 1
        if willShowIndex > count - 1 {
            willShowIndex = 0
        }

        let width = frame.size.width
        let height = frame.size.height

        if !(width > 0 && height > 0) {
            _needTryRoll = true
            return
        }

        // 安全获取cell，处理可能返回nil的情况
        if currentCell == nil {
            let cell = dataSource.rollingNoticeView(roolingView: self, cellAtIndex: _cIdx)
            currentCell = cell
            cell.frame = CGRect(x: 0, y: 0, width: width, height: height)
            addSubview(cell)
            return
        }

        let nextCell = dataSource.rollingNoticeView(roolingView: self, cellAtIndex: willShowIndex)
        
        // 确保之前的willShowCell被正确清理
        willShowCell?.removeFromSuperview()
        willShowCell = nextCell
        nextCell.frame = CGRect(x: 0, y: height, width: width, height: height)
        addSubview(nextCell)
        
        // 确保必需的cell都存在 - 修复条件绑定问题
        // 因为currentCell和willShowCell不是可选类型的局部变量，所以不需要条件绑定
        if currentCell == nil || willShowCell == nil {
            return
        }

        if GYRollingDebugLog {
            print("currentCell: ", currentCell)
            print("willShowCell: ", willShowCell)
        }

        // 安全移除cell引用，避免重复添加或移除
        if let currentCell = self.currentCell, let currentCellIdx = reuseCells.firstIndex(of: currentCell) {
            reuseCells.remove(at: currentCellIdx)
        }

        if let willShowCell = self.willShowCell, let willShowCellIdx = reuseCells.firstIndex(of: willShowCell) {
            reuseCells.remove(at: willShowCellIdx)
        }
    }

    @objc func handleCellTapAction() {
        delegate?.rollingNoticeView?(self, didClickAt: currentIndex)
    }

    func setupNoticeViews() {
        clipsToBounds = true
        addGestureRecognizer(createTapGesture())
    }

    func createTapGesture() -> UITapGestureRecognizer {
        UITapGestureRecognizer(
            target: self, action: #selector(GYRollingNoticeView.handleCellTapAction)
        )
    }
}
