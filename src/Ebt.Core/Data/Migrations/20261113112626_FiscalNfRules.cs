using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class FiscalNfRules : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "po_phrase",
                table: "customers",
                type: "text",
                nullable: true);

            // Sentences and names as the old NFs print them (only where the register still holds the seeded text).
            migrationBuilder.Sql("UPDATE cfops SET legal_text = 'MATERIAL DE NOSSA PROPRIEDADE QUE SEGUE PARA INDUSTRIALIZACAO DEVENDO RETORNAR PARA NOVA INDUSTRIALIZACAO E/OU COMERCIALIZACAO. IPI - SUSPENSO ART. 43, INC.VI E VII DEC.7212/10. ICMS - SUSPENSO ART. 402 DO DECRETO 45490/00.' WHERE code = '5901' AND legal_text LIKE 'Suspens%'");
            migrationBuilder.Sql("UPDATE cfops SET description = 'REMESSA DE EMBALAGEM' WHERE code = '5920' AND description = 'Remessa de vasilhame ou sacaria'");
            migrationBuilder.Sql("UPDATE cfops SET legal_text = 'ENVIO DE EMBALAGEM DE NOSSA PROPRIEDADE COM RETORNO POSTERIOR' WHERE code = '5920' AND (legal_text IS NULL OR legal_text = '')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "po_phrase",
                table: "customers");
        }
    }
}
