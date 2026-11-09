using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class SalesOrderRequestFile : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "request_file_name",
                table: "sales_orders",
                type: "character varying(255)",
                maxLength: 255,
                nullable: true);

            migrationBuilder.AddColumn<long>(
                name: "request_file_size",
                table: "sales_orders",
                type: "bigint",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "request_file_type",
                table: "sales_orders",
                type: "character varying(100)",
                maxLength: 100,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "sales_order_request_files",
                columns: table => new
                {
                    order_id = table.Column<int>(type: "integer", nullable: false),
                    data = table.Column<byte[]>(type: "bytea", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_sales_order_request_files", x => x.order_id);
                    table.ForeignKey(
                        name: "fk_sales_order_request_files_sales_orders_order_id",
                        column: x => x.order_id,
                        principalTable: "sales_orders",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "sales_order_request_files");

            migrationBuilder.DropColumn(
                name: "request_file_name",
                table: "sales_orders");

            migrationBuilder.DropColumn(
                name: "request_file_size",
                table: "sales_orders");

            migrationBuilder.DropColumn(
                name: "request_file_type",
                table: "sales_orders");
        }
    }
}
