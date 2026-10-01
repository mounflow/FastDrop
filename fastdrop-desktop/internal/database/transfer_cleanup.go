package database

import (
	"context"
	"fmt"
)

// DeleteTerminalTransfers 清空"已结束"的传输记录（本机历史页的「清空记录」）。
//
// 只删终态（completed / failed / cancelled / rejected）——进行中的传输必须
// 保留，否则接收/发送中途的状态更新会写到已删除的行上。子表按外键顺序
// 清理：file_chunk_states（按文件 id）→ transfer_files → transfers。
//
// 返回 (删除的传输条数, 删除的文件条数)。
func (d *DB) DeleteTerminalTransfers(ctx context.Context) (int64, int64, error) {
	const terminal = `('completed','failed','cancelled','rejected')`

	// 1. 分块位图：按待删文件的 id 清理。
	if _, err := d.ExecContext(ctx, fmt.Sprintf(`
DELETE FROM file_chunk_states WHERE file_id IN (
    SELECT f.id FROM transfer_files f
    JOIN transfers t ON t.id = f.transfer_id
    WHERE t.status IN %s)`, terminal)); err != nil {
		return 0, 0, fmt.Errorf("delete chunk states: %w", err)
	}

	// 2. 文件行。
	fileRes, err := d.ExecContext(ctx, fmt.Sprintf(`
DELETE FROM transfer_files WHERE transfer_id IN (
    SELECT id FROM transfers WHERE status IN %s)`, terminal))
	if err != nil {
		return 0, 0, fmt.Errorf("delete transfer files: %w", err)
	}
	filesDeleted, _ := fileRes.RowsAffected()

	// 3. 传输行。
	transferRes, err := d.ExecContext(ctx, fmt.Sprintf(`
DELETE FROM transfers WHERE status IN %s`, terminal))
	if err != nil {
		return 0, 0, fmt.Errorf("delete transfers: %w", err)
	}
	transfersDeleted, _ := transferRes.RowsAffected()

	return transfersDeleted, filesDeleted, nil
}
