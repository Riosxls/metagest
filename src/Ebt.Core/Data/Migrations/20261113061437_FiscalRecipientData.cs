using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class FiscalRecipientData : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "legal_name",
                table: "customers",
                type: "text",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "product_company_ncms",
                columns: table => new
                {
                    product_id = table.Column<int>(type: "integer", nullable: false),
                    company = table.Column<string>(type: "character varying(3)", maxLength: 3, nullable: false),
                    ncm = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_product_company_ncms", x => new { x.product_id, x.company });
                    table.ForeignKey(
                        name: "fk_product_company_ncms_products_product_id",
                        column: x => x.product_id,
                        principalTable: "products",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Cascade);
                });

            // The natureza da operacao printed on the NF follows the old system (the register held the official CFOP names).
            migrationBuilder.Sql("UPDATE cfops SET description = 'VENDA DE MERCADORIA' WHERE code = '5101' AND description = 'Venda de produção do estabelecimento'");
            migrationBuilder.Sql("UPDATE cfops SET description = 'REMESSA PARA INDUSTRIALIZACAO' WHERE code = '5901' AND description = 'Remessa para industrialização por encomenda'");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "product_company_ncms");

            migrationBuilder.DropColumn(
                name: "legal_name",
                table: "customers");
        }
    }
}
